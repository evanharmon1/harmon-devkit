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
#   2  indeterminate / malformed / changed head / usage error

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  check-codex-cloud-review.sh reserve --state FILE --repo OWNER/REPO --pr N --head SHA --attempt 1|2
  check-codex-cloud-review.sh attach --state FILE --trigger-id N
  check-codex-cloud-review.sh check --state FILE --actor-id N [--actor-login LOGIN] [--timeout-min N] [--now ISO8601]
  check-codex-cloud-review.sh show --state FILE
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
need git
need jq

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

state_file=
repo=
pr=
head=
attempt=
trigger_id=
actor_id=
actor_login='chatgpt-codex-connector[bot]'
timeout_min=15
now=

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state | --repo | --pr | --head | --attempt | --trigger-id | --actor-id | --actor-login | --timeout-min | --now)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --state) state_file=$2 ;;
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --attempt) attempt=$2 ;;
        --trigger-id) trigger_id=$2 ;;
        --actor-id) actor_id=$2 ;;
        --actor-login) actor_login=$2 ;;
        --timeout-min) timeout_min=$2 ;;
        --now) now=$2 ;;
        esac
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$state_file" ] || usage

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
    gh pr view "$1" --repo "$2" --json headRefOid,state |
        jq -er 'select(.state == "OPEN") | .headRefOid'
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
      (.phase == "reserved" or .phase == "attached")
    ' "$state_file" >/dev/null || die "malformed state file: $state_file"
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
    if ! gh api --paginate --slurp "$endpoint" >"$raw"; then
        return 1
    fi
    flatten_pages "$raw" "$destination" 2>/dev/null || return 1
}

case "$command_name" in
reserve)
    [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] && [ -n "$attempt" ] ||
        usage
    valid_repo "$repo" || die "invalid repository: $repo"
    valid_uint "$pr" || die "invalid PR number: $pr"
    valid_sha "$head" || die "head must be a full 40-hex commit"
    case "$attempt" in 1 | 2) ;; *) die "attempt must be 1 or 2" ;; esac

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
        if [ "$old_head" = "$head" ]; then
            if [ "$old_attempt" = "$attempt" ] && [ "$old_phase" = "reserved" ]; then
                die "attempt is already reserved; reconcile the external comment before retrying"
            fi
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
    payload=$(jq -cn \
        --arg repo "$repo" \
        --argjson pr "$pr" \
        --arg head "$head" \
        --argjson attempt "$attempt" \
        --arg reserved_at "$reserved_at" \
        '{
          version:1,repo:$repo,pr:$pr,head:$head,attempt:$attempt,
          phase:"reserved",reserved_at:$reserved_at,
          trigger_comment_id:null,requested_at:null
        }')
    write_state "$state_file" "$payload"
    printf '%s\n' "$payload"
    ;;

attach)
    [ -n "$trigger_id" ] || usage
    valid_uint "$trigger_id" || die "invalid trigger comment ID"
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
    live_head=$(provider_head "$state_pr" "$state_repo") ||
        die "cannot re-confirm the open PR head"
    [ "$live_head" = "$state_head" ] ||
        die "PR head changed before trigger attachment"

    comment=$(gh api "repos/$state_repo/issues/comments/$trigger_id") ||
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
          .requested_at = $requested_at
        ' "$state_file")
    write_state "$state_file" "$payload"
    printf '%s\n' "$payload"
    ;;

show)
    read_state
    cat "$state_file"
    ;;

check)
    [ -n "$actor_id" ] || usage
    valid_uint "$actor_id" || die "invalid actor ID"
    valid_uint "$timeout_min" || die "timeout must be a positive integer"
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
    state_requested=$(jq -r '.requested_at' "$state_file")
    valid_uint "$state_trigger" || die "state has an invalid trigger ID"
    valid_time "$state_requested" || die "state has an invalid request time"

    first_head=$(provider_head "$state_pr" "$state_repo") || {
        emit indeterminate "cannot fetch the current open PR head"
        exit 2
    }
    [ "$first_head" = "$state_head" ] || {
        emit head-changed "recorded evidence belongs to an older PR head"
        exit 2
    }

    workdir=$(mktemp -d -t codex-cloud-review-XXXXXX)
    trap 'rm -rf "$workdir"' EXIT

    actor=$(gh api "users/$actor_login") || {
        emit indeterminate "cannot authenticate the configured Codex actor"
        exit 2
    }
    printf '%s' "$actor" | jq -e \
        --argjson id "$actor_id" \
        --arg login "$actor_login" '
          (.id == $id) and (.login == $login) and (.type == "Bot")
        ' >/dev/null || {
        emit indeterminate "configured Codex login does not resolve to the pinned Bot actor ID"
        exit 2
    }

    trigger=$(gh api "repos/$state_repo/issues/comments/$state_trigger") || {
        emit indeterminate "cannot re-fetch the exact trigger comment"
        exit 2
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

    fetch_pages \
        "repos/$state_repo/issues/comments/$state_trigger/reactions?per_page=100" \
        "$workdir/reactions.json" ||
        {
            emit indeterminate "cannot fetch paginated exact-trigger reactions"
            exit 2
        }
    fetch_pages "repos/$state_repo/issues/$state_pr/comments?per_page=100" \
        "$workdir/comments.json" ||
        {
            emit indeterminate "cannot fetch paginated PR conversation comments"
            exit 2
        }
    fetch_pages "repos/$state_repo/pulls/$state_pr/reviews?per_page=100" \
        "$workdir/reviews.json" ||
        {
            emit indeterminate "cannot fetch paginated PR reviews"
            exit 2
        }
    fetch_pages "repos/$state_repo/pulls/$state_pr/comments?per_page=100" \
        "$workdir/inline.json" ||
        {
            emit indeterminate "cannot fetch paginated inline comments"
            exit 2
        }

    second_head=$(provider_head "$state_pr" "$state_repo") || {
        emit indeterminate "cannot re-fetch the PR head before verdict"
        exit 2
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

    inline_findings=$(jq \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" \
        --arg head "$state_head" '
          [.[] | select(
            .user.id? == $id and
            (.created_at? >= $requested) and
            (.commit_id? == $head)
          )] | length
        ' "$workdir/inline.json")
    if [ "$inline_findings" -gt 0 ]; then
        emit findings "authenticated current-head inline review findings require adjudication"
        exit 10
    fi

    review_result=$(jq -r \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" \
        --arg head "$state_head" '
          [.[] | select(
            .user.id? == $id and
            (.submitted_at? >= $requested) and
            (.commit_id? == $head)
          ) |
            if ((.body // "") | test(
              "didn.t find any major issues|no major issues|no findings";
              "i"
            )) then "clean" else "findings" end
          ] |
          if index("findings") then "findings"
          elif index("clean") then "clean"
          else "none" end
        ' "$workdir/reviews.json")
    if [ "$review_result" = "findings" ]; then
        emit findings "authenticated current-head review requires adjudication"
        exit 10
    fi

    comment_candidates="$workdir/comment-candidates.tsv"
    jq -r \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" '
          .[] | select(.user.id? == $id and (.created_at? >= $requested)) |
          ((.body // "") |
            try match(
              "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
              "i"
            ).captures[0].string catch "") as $prefix |
          select($prefix != "") |
          [
            $prefix,
            (if ((.body // "") | test(
              "didn.t find any major issues|no major issues|no findings";
              "i"
            )) then "clean" else "findings" end),
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
        resolved=$(git rev-parse --verify "${prefix}^{commit}" 2>/dev/null || true)
        [ "$resolved" = "$state_head" ] || {
            emit indeterminate "bot review comment is not unambiguously bound to the current head"
            exit 2
        }
        if [ "$classification" = "findings" ]; then
            comment_result=findings
        elif [ "$comment_result" = "none" ]; then
            comment_result=clean
        fi
        : "$comment_id"
    done <"$comment_candidates"

    if [ "$comment_result" = "findings" ]; then
        emit findings "authenticated current-head conversation finding requires adjudication"
        exit 10
    fi
    if [ "$review_result" = "clean" ] || [ "$comment_result" = "clean" ]; then
        emit clean "authenticated bot posted a current-head clean result"
        exit 0
    fi

    exact_like=$(jq \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" '
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

    if [ -z "$now" ]; then
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    fi
    valid_time "$now" || die "--now must be an ISO-8601 UTC second"
    requested_epoch=$(jq -nr --arg value "$state_requested" '$value | fromdateiso8601') ||
        die "cannot parse request time"
    now_epoch=$(jq -nr --arg value "$now" '$value | fromdateiso8601') ||
        die "cannot parse current time"
    [ "$now_epoch" -ge "$requested_epoch" ] || die "--now predates the request"
    elapsed=$((now_epoch - requested_epoch))
    timeout_seconds=$((timeout_min * 60))
    if [ "$elapsed" -lt "$timeout_seconds" ]; then
        emit pending "no terminal current-head evidence yet"
        exit 11
    fi
    if [ "$state_attempt" = "1" ]; then
        emit retry "attempt 1 completed without terminal current-head evidence"
        exit 12
    fi
    emit escalate "two attempts completed without terminal current-head evidence"
    exit 13
    ;;

*) usage ;;
esac
