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
          def verdict_tail:
            (first_line | ltrimstr(clean_sentence) |
              gsub("^[[:space:]]+|[[:space:]]+$"; ""));
          def has_severity_marker:
            (body_text | ascii_downcase | test("\\bp[0-2]\\b"));
          # The tail is judged by SHAPE, not by membership in a list of
          # strings we happen to have seen. The list could not converge:
          # seven distinct clauses were observed, three of them inside
          # twenty-five minutes, and one was an emoji shortcode — so every
          # unlisted clause was a false blocker on a clean review.
          #
          # Length alone cannot do it. The longest praise actually observed
          # is 41 characters ("already looking forward to the next diff."),
          # while real caveats are SHORTER than that: "But a race remains."
          # is 19. So the cap is a backstop against essays, and the
          # discriminating work is done by the shape rules below.
          #
          # Every rule rejects toward "unrecognized", which escalates to a
          # human. That is the safe direction: a rejected praise clause costs
          # one escalation, an accepted caveat passes a PR the reviewer
          # flagged.
          def praise_cap: 48;
          # A bare emoji shortcode (:+1:) is praise and contains a digit, so
          # it is matched before the digit rule below.
          # A CLOSED set of positive reactions. The previous rule accepted
          # any shortcode, so ":warning:" read as praise.
          def is_emoji_token:
            test("^:(\\+1|thumbsup|tada|rocket|fire|sparkles|clap|star|"
              + "stars|heart|hearts|100|trophy|medal|raised_hands|muscle|"
              + "ok_hand|grin|smile|tada2|partying_face):$");
          # There is deliberately no "any symbol-only tail is fine" rule.
          # It accepted the warning glyph, which asserts plenty.
          # POSITIVE recognition, over the WHOLE tail.
          #
          # Two earlier revisions of this test failed open, each more subtly:
          #
          #   1. reject known caveat shapes, accept the rest — a blocklist, so
          #      "Tests fail on Windows." passed, tripping no rule;
          #   2. accept if a praise word appears anywhere — so "Nice work,
          #      tests crash on Windows." passed on the strength of "nice".
          #
          # Both share a root cause: some part of the tail went unexamined.
          # The rule is therefore not "contains praise" but "is NOTHING BUT
          # praise". Every word must be recognised; one unknown word escalates.
          # That terminates, because there is no residue left for a concern to
          # hide in — a caveat has to name something, and the thing it names is
          # a word this vocabulary does not have.
          #
          # The vocabulary is of words rather than whole clauses, which is what
          # keeps it tractable: "Nice work!", "Nice job!" and "Very nice." are
          # covered by one entry where a clause list needed three.
          # Sentiment words. At least one must be present, or a phrase.
          def core_praise:
            test("^(nice|great|excellent|awesome|amazing|beautiful|lovely|"
              + "superb|stellar|brilliant|fantastic|terrific|wonderful|"
              + "impressive|bravo|kudos|chapeau|kiss|swish|delight|delightful|"
              + "love|loved|enjoyed|pleasure|flawless|spotless|exemplary|"
              + "admirable|perfect|ace|lgtm|solid|smooth|slick|elegant|"
              + "crisp|good|nicely|beautifully|cheers|thanks|thank)$");
          # Praise that only reads as praise as a whole phrase.
          def praise_phrase:
            test("keep it up|looking forward|on a roll|well done|hats off|"
              + "top.?notch|chef.?s kiss");
          def praise_word:
            test("^(nice|great|excellent|awesome|amazing|beautiful|lovely|"
              + "superb|stellar|brilliant|fantastic|terrific|wonderful|"
              + "impressive|bravo|kudos|chapeau|kiss|swish|delight|delightful|"
              + "love|loved|enjoyed|pleasure|flawless|spotless|exemplary|"
              + "admirable|perfect|ace|lgtm|solid|smooth|slick|elegant|"
              # NOTE: "clean", "tidy", "neat" and "sharp" are deliberately
              # ABSENT. Each doubles as an imperative verb, and with a deictic
              # they build an instruction out of nothing but allowed words —
              # "Clean this up." was clean until they were removed. For the
              # same reason no deictic ("this", "that", "these") is allowed:
              # a word that points at something is pointing at the code.
              + "crisp|elegant|good|well|done|"
              # Filler that carries no assertion on its own.
              + "work|job|stuff|one|it|up|on|a|an|the|to|and|of|as|is|are|"
              + "you|your|youre|you.re|chef|chefs|chef.s|"
              + "very|really|so|much|truly|quite|absolutely|simply|just|"
              + "keep|keeping|looking|forward|next|diff|pr|change|changes|"
              + "everyone|all|here|again|already|another|roll|notch|top|"
              + "hats|off|ship|thanks|thank|cheers|nicely|beautifully)$");
          # Everything after the verdict line must be Codex's own metadata:
          # the "Reviewed commit" line and its collapsed About block. A concern
          # parked on a later line carries no badge, so nothing else would
          # catch it.
          def praise_ok:
            verdict_tail as $t |
            if $t == "" then true
            elif ($t | is_emoji_token) then true
            elif ($t | length) > praise_cap then false
            # A reference to code or a location is a caveat, never praise.
            elif ($t | test("[`<>()\\[\\]/]|https?:|[0-9]")) then false
            # More than one sentence is an argument, not an interjection.
            elif ($t | test("[.!?][[:space:]]+[^[:space:]]")) then false
            # Default DENY, in two parts. Every word must be recognised —
            # so no unexamined residue is left for a concern to hide in — AND
            # the tail must carry actual praise, not merely permitted words.
            # Filler alone composes into imperatives: "Work on it.",
            # "Change it." and "Ship it." are built entirely from words that
            # were individually allowed.
            else ($t
              | gsub("[^a-z'\u2019[:space:]]"; " ") as $clean
              | ($clean | split(" ") | map(select(. != ""))) as $words
              | ($words | length > 0)
                and ($words | all(praise_word))
                and (($words | any(core_praise)) or ($clean | praise_phrase)))
            end;
          def rest_is_boilerplate:
            (body_text | split("\n") | .[1:] | join("\n") |
              gsub("<details.*?<summary>.*?about codex.*?</summary>.*?</details>";
                   ""; "im") |
              ascii_downcase | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
              map(select(. != "")) |
              all(test(
                "^\\*\\*reviewed commit:\\*\\*[[:space:]]*`[0-9a-f]{7,40}`[[:space:]]*$"
              )));
          def verdict_class:
            if (first_line | startswith(clean_sentence) | not) then "findings"
            elif has_severity_marker then "findings"
            elif (praise_ok | not) then "unrecognized"
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

    inline_findings=$(jq \
        --argjson id "$actor_id" \
        --arg head "$state_head" '
          [.[] | select(
            .user.id? == $id and
            (.original_commit_id? == $head)
          )] | length
        ' "$workdir/inline.json")
    if [ "$inline_findings" -gt 0 ]; then
        emit findings "authenticated current-head inline review findings require adjudication"
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
    #   * tail is empty or an OBSERVED praise string -> clean
    #   * anything else                             -> INDETERMINATE
    #
    # The tail is matched against a literal list, not a shape. Every shape
    # rule tried here admitted a negative qualifier of the same shape: "but a
    # race remains." and "one concern." are as short and as alphabetic as
    # "Chef's kiss.", so no pattern over characters can separate them. Only
    # positive recognition can.
    #
    # An allowlist is normally the brittle choice, and it was: while the
    # outcome was binary, an unlisted praise string had to be called
    # `findings`, which jammed a clean PR's gate and asserted something false.
    # The third branch is what makes it safe now — an unlisted tail is
    # `indeterminate`, so the shepherd stops and a human either recognises new
    # praise (add it below) or finds a real qualifier. The list is allowed to
    # be incomplete; it is not allowed to be wrong.
    #
    # Add a string here only after seeing Codex actually emit it.
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
    review_result=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        "$codex_verdict_defs"'
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head)
          ) | verdict_class
          ] |
          if index("findings") then "findings"
          elif index("unrecognized") then "unrecognized"
          elif index("clean") then "clean"
          else "none" end
        ' "$workdir/reviews.json")
    if [ "$review_result" = "findings" ]; then
        emit findings "authenticated current-head review requires adjudication"
        exit 10
    fi
    if [ "$review_result" = "unrecognized" ]; then
        emit indeterminate "current-head review opens with the clean verdict but its trailing clause is unrecognized"
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
        emit indeterminate "current-head result opens with the clean verdict but its trailing clause is unrecognized"
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

    bounded_wait "no terminal current-head evidence yet"
    ;;

*) usage ;;
esac
