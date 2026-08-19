#!/usr/bin/env bash
# claim-transaction.sh — publish a claim record as the claim's commit point.
#
# The durable comment is the boundary between tentative marker writes and a
# valid claim. Marker writes happen first, the exact record is published next,
# and the board is moved only after publication is known to have committed.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: claim-transaction.sh --repo owner/repo --issue N --record-file FILE
       --claim-label LABEL|none [--displaced-label LABEL|none]
       [--status-helper FILE] [--project TITLE]

Exit: 0 = record committed and board moved
      2 = usage, invalid record, or pre-write state could not be verified
      3 = record committed; repository has no writable board status
      4 = record did not commit; this attempt's marker writes were compensated
      5 = record committed; board move failed or could not be verified
      6 = publication/marker state is indeterminate; markers remain visible
      7 = record absent and compensation failed; partial recordless claim remains
EOF
    exit 2
}

repo=""
issue=""
record_file=""
claim_label=""
displaced_label="none"
status_helper=""
project_title=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --issue)
        [ "$#" -ge 2 ] || usage
        issue="$2"
        shift 2
        ;;
    --record-file)
        [ "$#" -ge 2 ] || usage
        record_file="$2"
        shift 2
        ;;
    --claim-label)
        [ "$#" -ge 2 ] || usage
        claim_label="$2"
        shift 2
        ;;
    --displaced-label)
        [ "$#" -ge 2 ] || usage
        displaced_label="$2"
        shift 2
        ;;
    --status-helper)
        [ "$#" -ge 2 ] || usage
        status_helper="$2"
        shift 2
        ;;
    --project)
        [ "$#" -ge 2 ] || usage
        project_title="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$issue" ] && [ -n "$record_file" ] && [ -n "$claim_label" ] || usage
case "$repo" in
*/*) ;;
*) usage ;;
esac
case "$issue" in
'' | *[!0-9]*) usage ;;
esac
[ -f "$record_file" ] || {
    echo "claim transaction: record file not found: $record_file" >&2
    exit 2
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -z "$status_helper" ]; then
    status_helper="$script_dir/../../track-work/assets/set-issue-status.sh"
fi
[ -x "$status_helper" ] || {
    echo "claim transaction: status helper is not executable: $status_helper" >&2
    exit 2
}
for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "claim transaction: $tool is required" >&2
        exit 2
    }
done

valid_label() {
    case "$1" in
    claim:* | agent:*) [[ "$1" =~ ^(claim|agent):[a-zA-Z0-9:._-]+$ ]] ;;
    *) return 1 ;;
    esac
}
if [ "$claim_label" != "none" ]; then
    valid_label "$claim_label" || {
        echo "claim transaction: invalid claim label: $claim_label" >&2
        exit 2
    }
fi
if [ "$displaced_label" != "none" ]; then
    valid_label "$displaced_label" || {
        echo "claim transaction: invalid displaced label: $displaced_label" >&2
        exit 2
    }
    [ "$claim_label" != "none" ] || {
        echo "claim transaction: cannot displace a label without a replacement" >&2
        exit 2
    }
    [ "$claim_label" != "$displaced_label" ] || {
        echo "claim transaction: replacement and displaced labels must differ" >&2
        exit 2
    }
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

issue_snapshot() {
    gh issue view "$issue" --repo "$repo" --json assignees,labels
}

comments_snapshot() {
    local owner="${repo%%/*}" name="${repo#*/}"
    gh api --paginate --slurp "repos/$owner/$name/issues/$issue/comments" | jq 'add // []'
}

has_assignee() {
    jq -e --arg login "$2" 'any(.assignees[]?; .login == $login)' "$1" >/dev/null
}

has_label() {
    jq -e --arg label "$2" 'any(.labels[]?; .name == $label)' "$1" >/dev/null
}

record_value() {
    local prefix="$1" out
    if ! out=$(awk -v prefix="$prefix" '
        index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
        END { if (count != 1 || value == "") exit 1; print value }
    ' "$record_file"); then
        echo "claim transaction: record must contain exactly one non-empty '$prefix<value>' line" >&2
        exit 2
    fi
    printf '%s' "$out"
}

record_token() {
    local value="$1"
    value="${value%%,*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

if ! head -n 1 "$record_file" | grep -q '^Claiming —'; then
    echo "claim transaction: record must start with 'Claiming —'" >&2
    exit 2
fi
grep -q '^Claim record (for `/wrap` — undo only what this claim added):$' "$record_file" || {
    echo "claim transaction: record is missing the Claim record heading" >&2
    exit 2
}

if ! gh api user --jq .login >"$tmp/login"; then
    echo "claim transaction: could not resolve the authenticated login" >&2
    exit 2
fi
login="$(tr -d '\r\n' <"$tmp/login")"
[[ "$login" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$ ]] || {
    echo "claim transaction: authenticated login is invalid or empty" >&2
    exit 2
}

if ! issue_snapshot >"$tmp/issue-before.json"; then
    echo "claim transaction: could not read the issue before writing" >&2
    exit 2
fi
if ! comments_snapshot >"$tmp/comments-before.json"; then
    echo "claim transaction: could not read comments before writing" >&2
    exit 2
fi

status_args=(--repo "$repo" --issue "$issue")
[ -n "$project_title" ] && status_args+=(--project "$project_title")
set +e
status_before="$($status_helper "${status_args[@]}" --show 2>"$tmp/status-show.err")"
status_read=$?
set -e
case "$status_read" in
0)
    board="$(printf '%s\n' "$status_before" | sed -n 's/^board=//p')"
    [ "$(printf '%s\n' "$status_before" | grep -c '^board=' || true)" -eq 1 ] && [ -n "$board" ] || {
        echo "claim transaction: status helper returned no unique board title" >&2
        exit 2
    }
    prior_status="$(printf '%s\n' "$status_before" | sed -n 's/^Status=//p')"
    [ "$(printf '%s\n' "$status_before" | grep -c '^Status=' || true)" -le 1 ] || {
        echo "claim transaction: status helper returned multiple Status values" >&2
        exit 2
    }
    [ -n "$prior_status" ] || prior_status="none"
    ;;
3)
    board="none"
    prior_status="none"
    ;;
1 | 2)
    board="unknown"
    prior_status="unknown"
    echo "claim transaction: board state is unreadable; the record and later board result will preserve that gap" >&2
    ;;
*)
    echo "claim transaction: status helper returned unexpected exit $status_read" >&2
    exit 2
    ;;
esac

assignee_preexisting=0
has_assignee "$tmp/issue-before.json" "$login" && assignee_preexisting=1
label_preexisting=0
if [ "$claim_label" != "none" ] && has_label "$tmp/issue-before.json" "$claim_label"; then
    label_preexisting=1
fi
if [ "$displaced_label" != "none" ]; then
    [ "$label_preexisting" -eq 0 ] || {
        echo "claim transaction: replacement label already exists during a takeover" >&2
        exit 2
    }
    has_label "$tmp/issue-before.json" "$displaced_label" || {
        echo "claim transaction: displaced label is not present in the pre-write state" >&2
        exit 2
    }
fi

expected_assignee="yes"
[ "$assignee_preexisting" -eq 1 ] && expected_assignee="no"
if [ "$claim_label" = "none" ]; then
    expected_label="n/a"
elif [ "$label_preexisting" -eq 1 ]; then
    expected_label="no"
else
    expected_label="$claim_label"
fi

record_board="$(record_value '- board: ')"
record_prior="$(record_value '- prior board status: ')"
record_assignee="$(record_token "$(record_value '- assignee added by this claim: ')")"
record_label="$(record_token "$(record_value '- `claim:` label added by this claim: ')")"
record_displaced="$(record_token "$(record_value '- `claim:` label displaced by this claim: ')")"
chain_assignee="$(record_token "$(record_value '- assignee owned by this claim chain: ')")"
chain_login="$(record_token "$(record_value '- assignee login owned by this claim chain: ')")"
chain_label="$(record_token "$(record_value '- `claim:` label owned by this claim chain: ')")"
chain_displaced="$(record_token "$(record_value '- `claim:` label displaced by this claim chain: ')")"

[ "$record_board" = "$board" ] || {
    echo "claim transaction: record board '$record_board' does not match '$board'" >&2
    exit 2
}
[ "$record_prior" = "$prior_status" ] || {
    echo "claim transaction: record prior status '$record_prior' does not match '$prior_status'" >&2
    exit 2
}
[ "$record_assignee" = "$expected_assignee" ] || {
    echo "claim transaction: assignee ownership must be '$expected_assignee'" >&2
    exit 2
}
[ "$record_label" = "$expected_label" ] || {
    echo "claim transaction: label ownership must be '$expected_label'" >&2
    exit 2
}
[ "$record_displaced" = "$displaced_label" ] || {
    echo "claim transaction: displaced label must be '$displaced_label'" >&2
    exit 2
}
case "$chain_assignee" in yes | no) ;; *)
    echo "claim transaction: claim-chain assignee must be yes or no" >&2
    exit 2
    ;;
esac
if [ "$chain_assignee" = yes ]; then
    [[ "$chain_login" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$ ]] || {
        echo "claim transaction: owned assignee login is invalid" >&2
        exit 2
    }
else
    [ "$chain_login" = none ] || {
        echo "claim transaction: unowned assignee login must be none" >&2
        exit 2
    }
fi
case "$chain_label" in no | n/a) ;; *) valid_label "$chain_label" || {
    echo "claim transaction: claim-chain label is invalid" >&2
    exit 2
} ;; esac
case "$chain_displaced" in none) ;; *) valid_label "$chain_displaced" || {
    echo "claim transaction: displaced claim-chain label is invalid" >&2
    exit 2
} ;; esac
[ "$expected_assignee" != yes ] || { [ "$chain_assignee" = yes ] && [ "$chain_login" = "$login" ]; } || {
    echo "claim transaction: a newly added assignee must initialize chain ownership" >&2
    exit 2
}
if [ "$expected_label" = "$claim_label" ] && [ "$claim_label" != none ]; then
    [ "$chain_label" = "$claim_label" ] || {
        echo "claim transaction: a newly added label must initialize chain ownership" >&2
        exit 2
    }
fi
if [ "$displaced_label" != none ]; then
    [ "$chain_displaced" = "$displaced_label" ] || {
        echo "claim transaction: a displaced label must initialize or preserve chain ownership" >&2
        exit 2
    }
fi

assignee_added=0
label_added=0
displaced_removed=0

compensate() {
    local snapshot="$1" failed=0
    if [ "$displaced_removed" -eq 1 ] && ! has_label "$snapshot" "$displaced_label"; then
        if ! gh issue edit "$issue" --repo "$repo" --add-label "$displaced_label"; then
            echo "claim transaction: COMPENSATION FAILED restoring displaced label '$displaced_label'" >&2
            failed=1
        fi
    fi
    if [ "$label_added" -eq 1 ] && has_label "$snapshot" "$claim_label"; then
        if ! gh issue edit "$issue" --repo "$repo" --remove-label "$claim_label"; then
            echo "claim transaction: COMPENSATION FAILED removing added label '$claim_label'" >&2
            failed=1
        fi
    fi
    if [ "$assignee_added" -eq 1 ] && has_assignee "$snapshot" "$login"; then
        if ! gh issue edit "$issue" --repo "$repo" --remove-assignee "$login"; then
            echo "claim transaction: COMPENSATION FAILED removing added assignee '$login'" >&2
            failed=1
        fi
    fi
    return "$failed"
}

compensate_after_read() {
    if ! issue_snapshot >"$tmp/issue-compensate.json"; then
        echo "claim transaction: current marker state is indeterminate; leaving visible markers for recovery" >&2
        return 6
    fi
    if compensate "$tmp/issue-compensate.json"; then
        return 4
    fi
    echo "claim transaction: partial recordless claim remains after failed compensation" >&2
    return 7
}

if [ "$assignee_preexisting" -eq 0 ]; then
    if gh issue edit "$issue" --repo "$repo" --add-assignee "$login"; then
        assignee_added=1
    else
        if ! issue_snapshot >"$tmp/issue-after-assignee.json"; then
            echo "claim transaction: assignee write is indeterminate; leaving any visible marker for recovery" >&2
            exit 6
        fi
        if has_assignee "$tmp/issue-after-assignee.json" "$login"; then
            assignee_added=1
            echo "claim transaction: assignee write returned failure but reconciliation confirmed it applied" >&2
        else
            exit 4
        fi
    fi
fi

if [ "$claim_label" != "none" ] && [ "$label_preexisting" -eq 0 ]; then
    label_args=("$issue" --repo "$repo" --add-label "$claim_label")
    [ "$displaced_label" != none ] && label_args+=(--remove-label "$displaced_label")
    if gh issue edit "${label_args[@]}"; then
        label_added=1
        [ "$displaced_label" != none ] && displaced_removed=1
    else
        if ! issue_snapshot >"$tmp/issue-after-label.json"; then
            echo "claim transaction: label write is indeterminate; leaving visible markers for recovery" >&2
            exit 6
        fi
        has_label "$tmp/issue-after-label.json" "$claim_label" && label_added=1
        if [ "$displaced_label" != none ] && ! has_label "$tmp/issue-after-label.json" "$displaced_label"; then
            displaced_removed=1
        fi
        intended=1
        [ "$label_added" -eq 1 ] || intended=0
        [ "$displaced_label" = none ] || [ "$displaced_removed" -eq 1 ] || intended=0
        if [ "$intended" -eq 1 ]; then
            echo "claim transaction: label write returned failure but reconciliation confirmed it applied" >&2
        else
            set +e
            compensate_after_read
            result=$?
            set -e
            exit "$result"
        fi
    fi
fi

if ! issue_snapshot >"$tmp/issue-before-record.json" || ! has_assignee "$tmp/issue-before-record.json" "$login"; then
    echo "claim transaction: no authenticated assignee backs the record; compensating tentative markers" >&2
    set +e
    compensate_after_read
    result=$?
    set -e
    exit "$result"
fi

record_committed=0
if gh issue comment "$issue" --repo "$repo" --body-file "$record_file"; then
    record_committed=1
else
    if ! comments_snapshot >"$tmp/comments-after.json"; then
        echo "claim transaction: record publication is indeterminate; leaving visible markers for recovery" >&2
        exit 6
    fi
    if jq -e --arg login "$login" --rawfile body "$record_file" \
        --slurpfile before "$tmp/comments-before.json" '
        ($body | sub("\\n+$"; "")) as $expected
        | ($before[0] | map(.id)) as $known
        | any(.[];
            .user.login == $login
            and .body == $expected
            and (.id as $id | ($known | index($id)) == null))
    ' "$tmp/comments-after.json" >/dev/null; then
        record_committed=1
        echo "claim transaction: comment command failed but reconciliation confirmed the exact record committed" >&2
    else
        echo "claim transaction: record publication is confirmed absent; compensating this attempt" >&2
        set +e
        compensate_after_read
        result=$?
        set -e
        exit "$result"
    fi
fi

[ "$record_committed" -eq 1 ] || {
    echo "claim transaction: internal error: record state unresolved" >&2
    exit 6
}
set +e
"$status_helper" "${status_args[@]}" --status "In Progress"
board_result=$?
set -e
case "$board_result" in
0) exit 0 ;;
3)
    echo "claim transaction: claim committed; no board status was available to move" >&2
    exit 3
    ;;
1 | 2)
    echo "claim transaction: VALID CLAIM COMMITTED, but the board move failed or is unverifiable" >&2
    exit 5
    ;;
*)
    echo "claim transaction: VALID CLAIM COMMITTED, but the board helper returned unexpected exit $board_result" >&2
    exit 5
    ;;
esac
