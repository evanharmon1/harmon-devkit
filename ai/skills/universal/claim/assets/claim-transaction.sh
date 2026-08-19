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
       --claim-label LABEL|none [--model-label LABEL|none]
       [--displaced-label LABEL|none]
       [--family SLUG] [--runtime-environment VALUE]
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
model_label="none"
displaced_label="none"
family=""
runtime_environment=""
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
    --model-label)
        [ "$#" -ge 2 ] || usage
        model_label="$2"
        shift 2
        ;;
    --displaced-label)
        [ "$#" -ge 2 ] || usage
        displaced_label="$2"
        shift 2
        ;;
    --family)
        [ "$#" -ge 2 ] || usage
        family="$2"
        shift 2
        ;;
    --runtime-environment)
        [ "$#" -ge 2 ] || usage
        runtime_environment="$2"
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
if [ "$model_label" != "none" ]; then
    [[ "$model_label" =~ ^claim:[a-z0-9]+(-[a-z0-9]+)*:[a-z0-9]+(-[a-z0-9]+)*$ ]] || {
        echo "claim transaction: invalid model label: $model_label" >&2
        exit 2
    }
    [ -n "$family" ] && [ "${model_label%:*}" = "claim:$family" ] || {
        echo "claim transaction: model label does not refine the trusted family" >&2
        exit 2
    }
    [ "$claim_label" != none ] || {
        echo "claim transaction: a model label requires a family marker" >&2
        exit 2
    }
fi
if [ "$displaced_label" != "none" ]; then
    valid_label "$displaced_label" || {
        echo "claim transaction: invalid displaced label: $displaced_label" >&2
        exit 2
    }
    { [ "$claim_label" != "none" ] || [ "$model_label" != "none" ]; } || {
        echo "claim transaction: cannot displace a label without a replacement" >&2
        exit 2
    }
    [ "$claim_label" != "$displaced_label" ] || {
        echo "claim transaction: replacement and displaced labels must differ" >&2
        exit 2
    }
fi
if [ -n "$family" ]; then
    case "$family" in
    *[!a-z0-9-]* | -* | *- | *--*)
        echo "claim transaction: invalid trusted family slug: $family" >&2
        exit 2
        ;;
    esac
fi
if [ -n "$runtime_environment" ]; then
    case "$runtime_environment" in
    host | devcontainer | coder | codespace | github-actions | unknown) ;;
    *)
        echo "claim transaction: invalid portable runtime environment: $runtime_environment" >&2
        exit 2
        ;;
    esac
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

record_line_value() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

canonical_login_set() {
    local value="$1"
    if [ "$value" = none ]; then
        return 0
    fi
    if ! jq -er --arg value "$value" '
        ($value | split(",")) as $items
        | select(($items | length) > 0 and ($items | length) <= 10)
        | select(all($items[];
            test("^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$")
            and . == ascii_downcase))
        | select(($items | sort | unique | join(",")) == $value)
        | $items[]
    ' <<<'null'; then
        echo "claim transaction: claim-chain assignee set is not canonical ('$value')" >&2
        return 1
    fi
}

# Transitional read support for bounded whitespace-separated v3 records that
# the dependency branch emitted before comma-canonical v3 became final.
read_login_set() {
    local value="$1" normalized count login
    if [[ "$value" == *,* ]] || [ "$value" = none ]; then
        canonical_login_set "$value"
        return
    fi
    normalized=""
    count=0
    for login in $value; do
        [[ "$login" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$ ]] &&
            [ "$login" = "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" ] || return 1
        count=$((count + 1))
        [ "$count" -le 10 ] || return 1
        printf '%s\n' "$normalized" | grep -Fxq "$login" && return 1
        normalized="${normalized}${normalized:+$'\n'}$login"
    done
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$normalized" | sort
}

optional_record_value() {
    local prefix="$1"
    awk -v prefix="$prefix" '
        index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
        END {
            if (count > 1 || (count == 1 && value == "")) exit 2
            if (count == 1) print value
        }
    ' "$2"
}

predecessor_owned_assignees() {
    local predecessor_json="$1" body_file="$tmp/predecessor-body" author value owned login direct
    [ "$(jq -r '.found' "$predecessor_json")" = true ] || return 0
    jq -r '.body' "$predecessor_json" >"$body_file"
    author="$(jq -r '.author' "$predecessor_json" | tr '[:upper:]' '[:lower:]')"
    if ! direct="$(optional_record_value '- assignee added by this claim: ' "$body_file")"; then
        return 1
    fi
    direct="$(record_token "$direct")"
    case "$direct" in yes | no | '') ;; *) return 1 ;; esac

    if ! value="$(optional_record_value '- assignee logins owned by this claim chain: ' "$body_file")"; then
        echo "claim transaction: predecessor assignee set is ambiguous or empty" >&2
        return 1
    fi
    if [ -n "$value" ]; then
        value="$(record_line_value "$value")"
        read_login_set "$value"
        return
    fi

    if ! owned="$(optional_record_value '- assignee owned by this claim chain: ' "$body_file")" ||
        ! login="$(optional_record_value '- assignee login owned by this claim chain: ' "$body_file")"; then
        echo "claim transaction: predecessor scalar assignee provenance is ambiguous" >&2
        return 1
    fi
    if [ -n "$owned" ] || [ -n "$login" ]; then
        owned="$(record_token "$owned")"
        login="$(record_token "$login")"
        case "$owned" in
        yes)
            [ -n "$login" ] || login="$author"
            [ "$login" != none ] && [[ "$login" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$ ]] || return 1
            printf '%s\n' "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
            [ "$direct" = yes ] && printf '%s\n' "$author"
            ;;
        no)
            [ -z "$login" ] || [ "$login" = none ] || return 1
            [ "$direct" = yes ] && printf '%s\n' "$author"
            ;;
        *) return 1 ;;
        esac
        return
    fi

    case "$direct" in
    yes) printf '%s\n' "$author" ;;
    no | '') ;;
    *) return 1 ;;
    esac
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

# The immediate latest trusted predecessor is the only source of inherited
# assignee ownership. A release comment resets the chain. Trust is the same as
# the lifecycle reader: repository owner or a current write-associated assignee.
if ! jq --arg owner "${repo%%/*}" --slurpfile issue "$tmp/issue-before.json" '
    def dl: (.user.login | ascii_downcase);
    def writeauth:
        (.author_association // "") as $a
        | (["OWNER", "MEMBER", "COLLABORATOR"] | index($a)) != null;
    def trusted_claimant:
        dl as $login
        | (($login == ($owner | ascii_downcase))
         or ([ $issue[0].assignees[].login | ascii_downcase ] | index($login) != null))
        and writeauth;
    def trusted_release:
        (.body | startswith("Claim released —"))
        and (trusted_claimant or dl == "github-actions[bot]");
    [ .[]
      | select(.body != null)
      | select(trusted_claimant or trusted_release) ] as $events
    | ([range(0; $events | length) as $i
        | select($events[$i] | trusted_release)
        | $i] | last // -1) as $release
    | ([range($release + 1; $events | length) as $i
        | select($events[$i]
                 | ((.body | startswith("Claiming —")) and trusted_claimant))
        | $events[$i]] | last // null) as $predecessor
    | if $predecessor == null then {found:false}
      else {found:true, id:$predecessor.id, author:$predecessor.user.login,
            body:$predecessor.body}
      end
' "$tmp/comments-before.json" >"$tmp/predecessor.json"; then
    echo "claim transaction: could not select the immediate trusted predecessor" >&2
    exit 2
fi
if ! predecessor_owned_assignees "$tmp/predecessor.json" >"$tmp/predecessor-assignees"; then
    echo "claim transaction: predecessor assignee provenance is unreadable" >&2
    exit 2
fi
predecessor_chain_label=""
predecessor_chain_model=""
if [ "$(jq -r '.found' "$tmp/predecessor.json")" = true ]; then
    jq -r '.body' "$tmp/predecessor.json" >"$tmp/predecessor-body-for-labels"
    predecessor_chain_label="$(optional_record_value '- `claim:` label owned by this claim chain: ' "$tmp/predecessor-body-for-labels")" || {
        echo "claim transaction: predecessor family-label provenance is ambiguous" >&2
        exit 2
    }
    predecessor_chain_model="$(optional_record_value '- `claim:` model label owned by this claim chain: ' "$tmp/predecessor-body-for-labels")" || {
        echo "claim transaction: predecessor model-label provenance is ambiguous" >&2
        exit 2
    }
    [ -z "$predecessor_chain_label" ] || predecessor_chain_label="$(record_token "$predecessor_chain_label")"
    [ -z "$predecessor_chain_model" ] || predecessor_chain_model="$(record_token "$predecessor_chain_model")"
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
model_preexisting=0
if [ "$model_label" != "none" ] && has_label "$tmp/issue-before.json" "$model_label"; then
    model_preexisting=1
fi
if [ "$displaced_label" != "none" ]; then
    if [ "$model_label" != none ]; then
        [ "$model_preexisting" -eq 0 ] || {
            echo "claim transaction: replacement model label already exists during a takeover" >&2
            exit 2
        }
    elif [ "$label_preexisting" -ne 0 ]; then
        echo "claim transaction: replacement label already exists during a takeover" >&2
        exit 2
    fi
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
if [ "$model_label" = "none" ]; then
    expected_model="n/a"
elif [ "$model_preexisting" -eq 1 ]; then
    expected_model="no"
else
    expected_model="$model_label"
fi

record_board="$(record_value '- board: ')"
record_prior="$(record_value '- prior board status: ')"
record_assignee="$(record_token "$(record_value '- assignee added by this claim: ')")"
record_label="$(record_token "$(record_value '- `claim:` label added by this claim: ')")"
record_model="$(optional_record_value '- `claim:` model label added by this claim: ' "$record_file")" || {
    echo "claim transaction: model-label ownership is duplicated or empty" >&2
    exit 2
}
[ -z "$record_model" ] || record_model="$(record_token "$record_model")"
record_displaced="$(record_token "$(record_value '- `claim:` label displaced by this claim: ')")"
record_family="$(optional_record_value '- family: ' "$record_file")" || {
    echo "claim transaction: family metadata is duplicated or empty" >&2
    exit 2
}
record_runtime="$(optional_record_value '- runtime environment: ' "$record_file")" || {
    echo "claim transaction: runtime metadata is duplicated or empty" >&2
    exit 2
}
chain_assignees="$(record_line_value "$(record_value '- assignee logins owned by this claim chain: ')")"
chain_label="$(record_token "$(record_value '- `claim:` label owned by this claim chain: ')")"
chain_model="$(optional_record_value '- `claim:` model label owned by this claim chain: ' "$record_file")" || {
    echo "claim transaction: claim-chain model ownership is duplicated or empty" >&2
    exit 2
}
[ -z "$chain_model" ] || chain_model="$(record_token "$chain_model")"
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
{ [ -z "$record_model" ] && [ "$model_label" = none ]; } || [ "$record_model" = "$expected_model" ] || {
    echo "claim transaction: model-label ownership must be '$expected_model'" >&2
    exit 2
}
[ "$record_displaced" = "$displaced_label" ] || {
    echo "claim transaction: displaced label must be '$displaced_label'" >&2
    exit 2
}
if [ -n "$record_family" ] || [ -n "$family" ]; then
    [ -n "$family" ] && [ "$record_family" = "$family" ] || {
        echo "claim transaction: record family must equal the trusted resolver output" >&2
        exit 2
    }
fi
if [ -n "$record_runtime" ] || [ -n "$runtime_environment" ]; then
    [ -n "$runtime_environment" ] && [ "$record_runtime" = "$runtime_environment" ] || {
        echo "claim transaction: record runtime environment must equal the portable resolver output" >&2
        exit 2
    }
fi
canonical_login_set "$chain_assignees" >/dev/null || exit 2
case "$chain_label" in no | n/a) ;; *) valid_label "$chain_label" || {
    echo "claim transaction: claim-chain label is invalid" >&2
    exit 2
} ;; esac
case "$chain_model" in
'' | no | n/a) ;;
*)
    [[ "$chain_model" =~ ^claim:[a-z0-9]+(-[a-z0-9]+)*:[a-z0-9]+(-[a-z0-9]+)*$ ]] &&
        [ -n "$family" ] && [ "${chain_model%:*}" = "claim:$family" ] || {
        echo "claim transaction: claim-chain model label is invalid" >&2
        exit 2
    }
    ;;
esac
case "$chain_displaced" in none) ;; *) valid_label "$chain_displaced" || {
    echo "claim transaction: displaced claim-chain label is invalid" >&2
    exit 2
} ;; esac
{
    while IFS= read -r inherited; do
        [ -n "$inherited" ] || continue
        has_assignee "$tmp/issue-before.json" "$inherited" && printf '%s\n' "$inherited"
    done <"$tmp/predecessor-assignees"
    [ "$expected_assignee" = yes ] && printf '%s\n' "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
    true
} | sort -u >"$tmp/expected-assignees"
expected_chain_assignees="$(paste -sd, "$tmp/expected-assignees")"
[ -n "$expected_chain_assignees" ] || expected_chain_assignees=none
[ "$chain_assignees" = "$expected_chain_assignees" ] || {
    echo "claim transaction: assignee set must be derived from the immediate predecessor plus this attempt ('$expected_chain_assignees')" >&2
    exit 2
}
if [ "$expected_label" = "$claim_label" ] && [ "$claim_label" != none ]; then
    [ "$chain_label" = "$claim_label" ] || {
        echo "claim transaction: a newly added label must initialize chain ownership" >&2
        exit 2
    }
elif [ "$claim_label" != none ] && [ "$label_preexisting" -eq 1 ]; then
    expected_chain_label=no
    [ "$predecessor_chain_label" = "$claim_label" ] && expected_chain_label="$claim_label"
    [ "$chain_label" = "$expected_chain_label" ] || {
        echo "claim transaction: pre-existing family-label ownership is not proven by the predecessor" >&2
        exit 2
    }
fi
if [ "$expected_model" = "$model_label" ] && [ "$model_label" != none ]; then
    [ "$chain_model" = "$model_label" ] || {
        echo "claim transaction: a newly added model label must initialize chain ownership" >&2
        exit 2
    }
elif [ "$model_label" != none ] && [ "$model_preexisting" -eq 1 ]; then
    expected_chain_model=no
    [ "$predecessor_chain_model" = "$model_label" ] && expected_chain_model="$model_label"
    [ "$chain_model" = "$expected_chain_model" ] || {
        echo "claim transaction: pre-existing model-label ownership is not proven by the predecessor" >&2
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
model_added=0
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
    if [ "$model_added" -eq 1 ] && has_label "$snapshot" "$model_label"; then
        if ! gh issue edit "$issue" --repo "$repo" --remove-label "$model_label"; then
            echo "claim transaction: COMPENSATION FAILED removing added model label '$model_label'" >&2
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

if { [ "$claim_label" != "none" ] && [ "$label_preexisting" -eq 0 ]; } ||
    { [ "$model_label" != "none" ] && [ "$model_preexisting" -eq 0 ]; }; then
    label_args=("$issue" --repo "$repo")
    [ "$claim_label" = none ] || [ "$label_preexisting" -eq 1 ] || label_args+=(--add-label "$claim_label")
    [ "$model_label" = none ] || [ "$model_preexisting" -eq 1 ] || label_args+=(--add-label "$model_label")
    [ "$displaced_label" != none ] && label_args+=(--remove-label "$displaced_label")
    if gh issue edit "${label_args[@]}"; then
        [ "$claim_label" = none ] || [ "$label_preexisting" -eq 1 ] || label_added=1
        [ "$model_label" = none ] || [ "$model_preexisting" -eq 1 ] || model_added=1
        [ "$displaced_label" != none ] && displaced_removed=1
    else
        if ! issue_snapshot >"$tmp/issue-after-label.json"; then
            echo "claim transaction: label write is indeterminate; leaving visible markers for recovery" >&2
            exit 6
        fi
        if [ "$claim_label" != none ] && has_label "$tmp/issue-after-label.json" "$claim_label"; then
            label_added=1
        fi
        if [ "$model_label" != none ] && has_label "$tmp/issue-after-label.json" "$model_label"; then
            model_added=1
        fi
        if [ "$displaced_label" != none ] && ! has_label "$tmp/issue-after-label.json" "$displaced_label"; then
            displaced_removed=1
        fi
        intended=1
        [ "$claim_label" = none ] || [ "$label_preexisting" -eq 1 ] || [ "$label_added" -eq 1 ] || intended=0
        [ "$model_label" = none ] || [ "$model_preexisting" -eq 1 ] || [ "$model_added" -eq 1 ] || intended=0
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
