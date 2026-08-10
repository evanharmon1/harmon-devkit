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
#   2  indeterminate — malformed, changed head, usage error, or a
#      current-head verdict whose shape cannot be classified
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
  check-codex-cloud-review.sh show --state FILE
  check-codex-cloud-review.sh reap --root DIR [--budget-sec N]
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
now=
lock_dir=
reap_entries=
reap_lock=
reap_budget_sec=60
reap_deadline_epoch=

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state | --root | --repo | --pr | --head | --attempt | --trigger-id | --actor-id | --actor-login | --timeout-min | --budget-sec | --now)
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
        --timeout-min) timeout_min=$2 ;;
        --budget-sec) reap_budget_sec=$2 ;;
        --now) now=$2 ;;
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

provider_head() {
    run_gh pr view "$1" --repo "$2" --json headRefOid,state |
        jq -er 'select(.state == "OPEN") | .headRefOid'
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

read_state() {
    [ -f "$state_file" ] || die "state file does not exist: $state_file"
    jq -e '
      type == "object" and
      (.version == 1) and
      (.repo | type == "string") and
      (.pr | type == "number") and
      (.head | type == "string") and
      (.attempt == 1 or .attempt == 2) and
      (.phase == "reserved" or .phase == "attached") and
      (.cycle_requested_at == null or
        (.cycle_requested_at | type == "string")) and
      (.previous_trigger_comment_id == null or
        (.previous_trigger_comment_id | type == "number"))
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
          def first_line:
            (body_text | split("\n")[0] |
              gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase);
          def has_severity_marker:
            (body_text | ascii_downcase | test("\\bp[0-2]\\b"));
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
          #   2. the absence of any P0/P1/P2 badge ANYWHERE in the body —
          #      every finding Codex has ever posted here carried one;
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

    live_head=$(provider_head "$pr" "$repo") ||
        die "cannot confirm the open PR head"
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
        current_epoch=$(date -u '+%s')
        [ "$current_epoch" -ge \
            "$((previous_reserved_epoch + timeout_min * 60))" ] ||
            die "attempt 1 window has not elapsed"
    fi
    payload=$(jq -cn \
        --arg repo "$repo" \
        --argjson pr "$pr" \
        --arg head "$head" \
        --argjson attempt "$attempt" \
        --arg reserved_at "$reserved_at" \
        --arg cycle_requested_at "$cycle_requested_at" \
        --argjson previous_trigger_id "$previous_trigger_id" \
        '{
          version:1,repo:$repo,pr:$pr,head:$head,attempt:$attempt,
          phase:"reserved",reserved_at:$reserved_at,
          trigger_comment_id:null,requested_at:null,
          cycle_requested_at:
            (if $cycle_requested_at == "" then null else $cycle_requested_at end),
          previous_trigger_comment_id:$previous_trigger_id
        }')
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

attach)
    [ -n "$trigger_id" ] || usage
    valid_uint "$trigger_id" || die "invalid trigger comment ID"
    acquire_state_lock
    read_state
    phase=$(jq -r '.phase' "$state_file")
    if [ "$phase" = "attached" ]; then
        existing_id=$(jq -r '.trigger_comment_id' "$state_file")
        [ "$existing_id" = "$trigger_id" ] ||
            die "state is already attached to a different trigger"
        cat "$state_file"
        exit 0
    fi

    state_repo=$(jq -r '.repo' "$state_file")
    state_pr=$(jq -r '.pr' "$state_file")
    state_head=$(jq -r '.head' "$state_file")
    state_reserved=$(jq -r '.reserved_at' "$state_file")
    valid_time "$state_reserved" || die "state has an invalid reservation time"
    live_head=$(provider_head "$state_pr" "$state_repo") ||
        die "cannot re-confirm the open PR head"
    [ "$live_head" = "$state_head" ] ||
        die "PR head changed before trigger attachment"

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
                type == "object" and (.version == 1) and
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

    first_head=$(provider_head "$state_pr" "$state_repo") || {
        bounded_wait "cannot fetch the current open PR head"
    }
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

    second_head=$(provider_head "$state_pr" "$state_repo") || {
        bounded_wait "cannot re-fetch the PR head before verdict"
    }
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
    # carrying a P0/P1/P2 badge — which are rejected before this point. So the
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
    #   * carries a P0/P1/P2 marker anywhere        -> findings
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
    # P0/P1/P2 badge is never settled by its inline comments, however well
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
    review_result=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --argjson settled "$settled_reviews" \
        "$codex_verdict_defs"'
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head)
          ) |
          . as $review | verdict_class as $class |
          if $class == "findings" then
            (if (($review.id? | type) == "number") and
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
            (.id | tostring)
          ] | @tsv
        ' "$workdir/comments.json" >"$comment_candidates"

    comment_result=none
    while IFS='	' read -r prefix classification comment_id; do
        [ -n "$prefix" ] || continue
        printf '%s' "$prefix" | grep -Eq '^[0-9a-fA-F]{7,40}$' || {
            emit indeterminate "bot review comment contains a malformed commit prefix"
            exit 2
        }
        prefix_lower=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
        head_lower=$(printf '%s' "$state_head" | tr '[:upper:]' '[:lower:]')
        case "$head_lower" in "$prefix_lower"*) ;; *) continue ;; esac
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
        emit clean "authenticated bot posted a current-head clean result"
        exit 0
    fi

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
        emit clean "current-head findings are all adjudicated by trusted in-thread replies"
        exit 0
    fi

    bounded_wait "no terminal current-head evidence yet"
    ;;

*) usage ;;
esac
