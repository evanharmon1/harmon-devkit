#!/usr/bin/env bash
# claim-transaction.sh — publish a claim record as the claim's commit point.
#
# The durable comment is the boundary between tentative marker writes and a
# valid claim. Marker writes happen first and the exact record is published
# next. Project fields are deliberately outside the claim contract.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: claim-transaction.sh --repo owner/repo --issue N --record-file FILE
       --claim-label LABEL|none [--allow-label-less] [--model-label LABEL|none]
       [--family SLUG] [--runtime-environment VALUE]
       --registry-snapshot FILE|none

Exit: 0 = record committed
      2 = usage, invalid record, or pre-write state could not be verified
      6 = publication/marker state is indeterminate; markers remain visible
EOF
    exit 2
}

repo=""
issue=""
record_file=""
claim_label=""
model_label="none"
family=""
runtime_environment=""
registry_snapshot=""
allow_label_less=0
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
    --allow-label-less)
        allow_label_less=1
        shift
        ;;
    --model-label)
        [ "$#" -ge 2 ] || usage
        model_label="$2"
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
    --registry-snapshot)
        [ "$#" -ge 2 ] || usage
        registry_snapshot="$2"
        shift 2
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$issue" ] && [ -n "$record_file" ] && [ -n "$claim_label" ] &&
    [ -n "$registry_snapshot" ] || usage
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
label_required=1
if [ "$claim_label" = none ]; then
    [ "$allow_label_less" -eq 1 ] && [ "$model_label" = none ] || {
        echo "claim transaction: label-less claims require --allow-label-less and cannot carry a model label" >&2
        exit 2
    }
    label_required=0
else
    [ "$allow_label_less" -eq 0 ] || {
        echo "claim transaction: --allow-label-less is valid only with --claim-label none" >&2
        exit 2
    }
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
fi
if [ -n "$family" ]; then
    case "$family" in
    *[!a-z0-9-]* | -* | *- | *--*)
        echo "claim transaction: invalid trusted family slug: $family" >&2
        exit 2
        ;;
    esac
fi
legacy_labels_for_pre_field_registry() {
    case "$1" in
    claude) printf '%s\n' agent:claude-code ;;
    gpt) printf '%s\n' agent:codex ;;
    gemini) printf '%s\n' agent:gemini-cli ;;
    kimi) printf '%s\n' agent:kimi-k2 ;;
    qwen) printf '%s\n' agent:qwen-code ;;
    esac
}
finite_legacy_label_matches_family() {
    local aliases
    aliases="$(legacy_labels_for_pre_field_registry "$family")"
    printf '%s\n' "$aliases" | grep -Fqx "$claim_label"
}
legacy_label_matches_family() {
    local has_aliases
    [ -n "$family" ] || return 1
    if [ "$registry_snapshot" != none ]; then
        [ -r "$registry_snapshot" ] || return 1
        [ "$(jq -r --arg family "$family" '[.families[]? | select(.slug == $family)] | length' "$registry_snapshot")" = 1 ] ||
            return 1
        has_aliases="$(jq -r --arg family "$family" '.families[] | select(.slug == $family) | has("legacy_claim_labels")' "$registry_snapshot")" ||
            return 1
        if [ "$has_aliases" = true ]; then
            jq -e --arg family "$family" --arg label "$claim_label" '
                .families[] | select(.slug == $family)
                | (.legacy_claim_labels | type == "array")
                  and any(.legacy_claim_labels[]; . == $label)
            ' "$registry_snapshot" >/dev/null
            return
        fi
    fi
    finite_legacy_label_matches_family
}
case "$claim_label" in
none) ;;
claim:*)
    [ -n "$family" ] &&
        [[ "$claim_label" =~ ^claim:${family}(:[a-z0-9]+(-[a-z0-9]+)*)?$ ]] || {
        echo "claim transaction: family claim label does not match the trusted family" >&2
        exit 2
    }
    ;;
agent:*)
    legacy_label_matches_family || {
        echo "claim transaction: legacy claim label does not match the trusted family" >&2
        exit 2
    }
    if [ "$model_label" != none ] && ! finite_legacy_label_matches_family; then
        echo "claim transaction: a custom legacy alias cannot safely own a model refinement" >&2
        exit 2
    fi
    ;;
esac
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
    gh issue view "$issue" --repo "$repo" --json state,assignees,labels
}

comments_snapshot() {
    local owner="${repo%%/*}" name="${repo#*/}"
    gh api --paginate --slurp "repos/$owner/$name/issues/$issue/comments" | jq 'add // []'
}

timeline_snapshot() {
    local owner="${repo%%/*}" name="${repo#*/}"
    gh api --paginate --slurp "repos/$owner/$name/issues/$issue/timeline" | jq 'add // []'
}

select_predecessor() {
    local issue_file="$1" comments_file="$2" output_file="$3"
    jq --arg owner "${repo%%/*}" --slurpfile issue "$issue_file" '
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
                created_at:$predecessor.created_at, body:$predecessor.body}
          end
    ' "$comments_file" >"$output_file"
}

same_predecessor() {
    [ "$(jq -Sc . "$1")" = "$(jq -Sc . "$2")" ]
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

marker_continuous_since_predecessor() {
    local kind="$1" marker="$2" predecessor_json="$3" timeline_file="$4" created_at
    created_at="$(jq -er '.created_at | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
        "$predecessor_json")" || return 2
    jq -e '
        all(.[];
            if .event == "unassigned" then
                (.created_at | type == "string") and (.assignee.login | type == "string")
            elif .event == "unlabeled" then
                (.created_at | type == "string") and (.label.name | type == "string")
            else true
            end)
    ' "$timeline_file" >/dev/null || return 2
    case "$kind" in
    assignee)
        ! jq -e --arg marker "$marker" --arg since "$created_at" '
            any(.[];
                .event == "unassigned"
                and (.assignee.login | ascii_downcase) == ($marker | ascii_downcase)
                and .created_at >= $since)
        ' "$timeline_file" >/dev/null
        ;;
    label)
        ! jq -e --arg marker "$marker" --arg since "$created_at" '
            any(.[];
                .event == "unlabeled"
                and .label.name == $marker
                and .created_at >= $since)
        ' "$timeline_file" >/dev/null
        ;;
    *) return 2 ;;
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
if ! select_predecessor "$tmp/issue-before.json" "$tmp/comments-before.json" "$tmp/predecessor.json"; then
    echo "claim transaction: could not select the immediate trusted predecessor" >&2
    exit 2
fi
resume_exact=0
if jq -e --arg login "$login" --rawfile body "$record_file" '
    ($body | sub("\\n+$"; "")) as $expected
    | .found == true and .author == $login and .body == $expected
' "$tmp/predecessor.json" >/dev/null; then
    resume_exact=1
fi
if ! predecessor_owned_assignees "$tmp/predecessor.json" >"$tmp/predecessor-assignees-recorded"; then
    echo "claim transaction: predecessor assignee provenance is unreadable" >&2
    exit 2
fi
predecessor_chain_label=""
predecessor_chain_model=""
predecessor_chain_displaced=""
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
    # Pre-chain records can still carry exact, named direct ownership. Preserve
    # that authority across a refresh, while deliberately refusing legacy
    # `yes`: unnamed ownership cannot be made exact after superseding its only
    # durable record.
    if [ -z "$predecessor_chain_label" ]; then
        predecessor_direct_label="$(optional_record_value '- `claim:` label added by this claim: ' "$tmp/predecessor-body-for-labels")" || {
            echo "claim transaction: predecessor direct family-label provenance is ambiguous" >&2
            exit 2
        }
        if [ -z "$predecessor_direct_label" ]; then
            predecessor_direct_label="$(optional_record_value '- `agent:` label added by this claim: ' "$tmp/predecessor-body-for-labels")" || {
                echo "claim transaction: predecessor legacy direct family-label provenance is ambiguous" >&2
                exit 2
            }
        fi
        predecessor_direct_label="$(record_token "$predecessor_direct_label")"
        if valid_label "$predecessor_direct_label"; then
            predecessor_chain_label="$predecessor_direct_label"
        fi
    fi
    if [ -z "$predecessor_chain_model" ]; then
        predecessor_direct_model="$(optional_record_value '- `claim:` model label added by this claim: ' "$tmp/predecessor-body-for-labels")" || {
            echo "claim transaction: predecessor direct model-label provenance is ambiguous" >&2
            exit 2
        }
        predecessor_direct_model="$(record_token "$predecessor_direct_model")"
        if valid_label "$predecessor_direct_model"; then
            predecessor_chain_model="$predecessor_direct_model"
        fi
    fi
    predecessor_chain_displaced="$(optional_record_value '- `claim:` label displaced by this claim chain: ' "$tmp/predecessor-body-for-labels")" || {
        echo "claim transaction: predecessor displaced-label provenance is ambiguous" >&2
        exit 2
    }
    if [ -z "$predecessor_chain_displaced" ]; then
        predecessor_chain_displaced="$(optional_record_value '- `claim:` label displaced by this claim: ' "$tmp/predecessor-body-for-labels")" || {
            echo "claim transaction: predecessor direct displacement is ambiguous" >&2
            exit 2
        }
    fi
    [ -z "$predecessor_chain_label" ] || predecessor_chain_label="$(record_token "$predecessor_chain_label")"
    [ -z "$predecessor_chain_model" ] || predecessor_chain_model="$(record_token "$predecessor_chain_model")"
    [ -z "$predecessor_chain_displaced" ] || predecessor_chain_displaced="$(record_token "$predecessor_chain_displaced")"
fi

# A predecessor record proves what that claim owned when it was published, not
# that ownership remained continuous. GitHub's paginated timeline is the
# durable evidence for removals. A removed marker that was independently
# re-added is live state, but it is not cleanup authority this chain may inherit.
: >"$tmp/predecessor-assignees"
if [ "$(jq -r '.found' "$tmp/predecessor.json")" = true ] &&
    { [ -s "$tmp/predecessor-assignees-recorded" ] ||
        [ -n "$predecessor_chain_label" ] || [ -n "$predecessor_chain_model" ]; }; then
    if ! timeline_snapshot >"$tmp/timeline-before.json"; then
        echo "claim transaction: marker continuity timeline is unreadable" >&2
        exit 2
    fi
    while IFS= read -r inherited; do
        [ -n "$inherited" ] || continue
        if marker_continuous_since_predecessor assignee "$inherited" "$tmp/predecessor.json" \
            "$tmp/timeline-before.json"; then
            continuity_rc=0
        else
            continuity_rc=$?
        fi
        [ "$continuity_rc" -ne 2 ] || {
            echo "claim transaction: predecessor assignee continuity is ambiguous" >&2
            exit 2
        }
        [ "$continuity_rc" -eq 0 ] && printf '%s\n' "$inherited" >>"$tmp/predecessor-assignees"
    done <"$tmp/predecessor-assignees-recorded"
    if [ -n "$predecessor_chain_label" ]; then
        if marker_continuous_since_predecessor label "$predecessor_chain_label" "$tmp/predecessor.json" \
            "$tmp/timeline-before.json"; then
            continuity_rc=0
        else
            continuity_rc=$?
        fi
        [ "$continuity_rc" -ne 2 ] || {
            echo "claim transaction: predecessor family-label continuity is ambiguous" >&2
            exit 2
        }
        [ "$continuity_rc" -eq 0 ] || predecessor_chain_label=""
    fi
    if [ -n "$predecessor_chain_model" ]; then
        if marker_continuous_since_predecessor label "$predecessor_chain_model" "$tmp/predecessor.json" \
            "$tmp/timeline-before.json"; then
            continuity_rc=0
        else
            continuity_rc=$?
        fi
        [ "$continuity_rc" -ne 2 ] || {
            echo "claim transaction: predecessor model-label continuity is ambiguous" >&2
            exit 2
        }
        [ "$continuity_rc" -eq 0 ] || predecessor_chain_model=""
    fi
fi

inherited_continuity_required=0
if [ -s "$tmp/predecessor-assignees" ] || [ -n "$predecessor_chain_label" ] ||
    [ -n "$predecessor_chain_model" ]; then
    inherited_continuity_required=1
fi
inherited_continuity_holds() {
    local timeline_file="$1" inherited
    while IFS= read -r inherited; do
        [ -n "$inherited" ] || continue
        marker_continuous_since_predecessor assignee "$inherited" "$tmp/predecessor.json" \
            "$timeline_file" || return 1
    done <"$tmp/predecessor-assignees"
    [ -z "$predecessor_chain_label" ] ||
        marker_continuous_since_predecessor label "$predecessor_chain_label" "$tmp/predecessor.json" \
            "$timeline_file" || return 1
    [ -z "$predecessor_chain_model" ] ||
        marker_continuous_since_predecessor label "$predecessor_chain_model" "$tmp/predecessor.json" \
            "$timeline_file" || return 1
}

claim_blockers_absent() {
    local snapshot="$1" assigned live_label
    [ "$(jq -r '.state' "$snapshot")" = OPEN ] || return 1
    while IFS= read -r assigned; do
        [ -n "$assigned" ] || continue
        [ "$(printf '%s' "$assigned" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')" ] && continue
        grep -Fxiq "$assigned" "$tmp/predecessor-assignees" || return 1
    done < <(jq -r '.assignees[]?.login' "$snapshot")
    while IFS= read -r live_label; do
        case "$live_label" in
        claim:* | agent:*)
            [ "$live_label" = "$claim_label" ] || [ "$live_label" = "$model_label" ] || return 1
            ;;
        esac
    done < <(jq -r '.labels[]?.name' "$snapshot")
}

if [ "$resume_exact" -eq 0 ] && ! claim_blockers_absent "$tmp/issue-before.json"; then
    echo "claim transaction: issue state, assignees, or ownership labels changed into a claim blocker" >&2
    exit 2
fi

assignee_preexisting=0
has_assignee "$tmp/issue-before.json" "$login" && assignee_preexisting=1
label_preexisting=0
if [ "$label_required" -eq 1 ] && has_label "$tmp/issue-before.json" "$claim_label"; then
    label_preexisting=1
fi
model_preexisting=0
if [ "$model_label" != "none" ] && has_label "$tmp/issue-before.json" "$model_label"; then
    model_preexisting=1
fi

expected_assignee="yes"
[ "$assignee_preexisting" -eq 1 ] && expected_assignee="no"
if [ "$label_required" -eq 0 ]; then
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

case "$record_assignee" in yes | no) ;; *)
    echo "claim transaction: assignee ownership must be yes or no" >&2
    exit 2
    ;;
esac
{ [ "$label_required" -eq 0 ] && [ "$record_label" = n/a ]; } ||
    { [ "$label_required" -eq 1 ] &&
        { [ "$record_label" = "$claim_label" ] || [ "$record_label" = no ]; }; } || {
    echo "claim transaction: direct family-label ownership does not match the requested marker" >&2
    exit 2
}
if [ "$model_label" = none ]; then
    [ -z "$record_model" ] || [ "$record_model" = n/a ] || {
        echo "claim transaction: a model-less record must use n/a model ownership" >&2
        exit 2
    }
else
    [ "$record_model" = "$model_label" ] || [ "$record_model" = no ] || {
        echo "claim transaction: direct model-label ownership does not match the requested marker" >&2
        exit 2
    }
fi
[ "$record_displaced" = none ] || {
    echo "claim transaction: routine claims cannot record a directly displaced label" >&2
    exit 2
}

if [ "$resume_exact" -eq 0 ]; then
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
fi
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
claim_is_live() {
    local snapshot="$1"
    claim_blockers_absent "$snapshot" &&
        has_assignee "$snapshot" "$login" &&
        { [ "$label_required" -eq 0 ] || has_label "$snapshot" "$claim_label"; } &&
        { [ "$model_label" = none ] || has_label "$snapshot" "$model_label"; } &&
        { [ "$chain_displaced" = none ] || ! has_label "$snapshot" "$chain_displaced"; }
}
current_record_is_live() {
    local issue_output="$1" comments_output="$2" predecessor_output="$3" timeline_output="$4"
    issue_snapshot >"$issue_output" &&
        comments_snapshot >"$comments_output" &&
        { [ "$inherited_continuity_required" -eq 0 ] ||
            { timeline_snapshot >"$timeline_output" && inherited_continuity_holds "$timeline_output"; }; } &&
        select_predecessor "$issue_output" "$comments_output" "$predecessor_output" &&
        jq -e --arg login "$login" --rawfile body "$record_file" '
            ($body | sub("\\n+$"; "")) as $expected
            | .found == true and .author == $login and .body == $expected
        ' "$predecessor_output" >/dev/null &&
        claim_is_live "$issue_output"
}
if [ "$resume_exact" -eq 1 ]; then
    claim_is_live "$tmp/issue-before.json" || {
        echo "claim transaction: exact current record lacks an OPEN issue or its required live markers" >&2
        exit 6
    }
    exit 0
fi
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
if [ "$label_required" -eq 0 ]; then
    [ "$chain_label" = n/a ] || {
        echo "claim transaction: a label-less claim must record n/a chain ownership" >&2
        exit 2
    }
elif [ "$expected_label" = "$claim_label" ]; then
    [ "$chain_label" = "$claim_label" ] || {
        echo "claim transaction: a newly added label must initialize chain ownership" >&2
        exit 2
    }
elif [ "$label_preexisting" -eq 1 ]; then
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
expected_chain_displaced=none
[ -z "$predecessor_chain_displaced" ] || expected_chain_displaced="$predecessor_chain_displaced"
[ "$chain_displaced" = "$expected_chain_displaced" ] || {
    echo "claim transaction: displaced-label chain must come from the immediate predecessor" >&2
    exit 2
}

if [ "$assignee_preexisting" -eq 0 ]; then
    if ! gh issue edit "$issue" --repo "$repo" --add-assignee "$login"; then
        if ! issue_snapshot >"$tmp/issue-after-assignee.json"; then
            echo "claim transaction: assignee write is indeterminate; leaving any visible marker for recovery" >&2
            exit 6
        fi
        if has_assignee "$tmp/issue-after-assignee.json" "$login"; then
            echo "claim transaction: assignee write returned failure and visible assignment has ambiguous provenance" >&2
            exit 6
        fi
        echo "claim transaction: assignee write failed; no destructive recovery is safe" >&2
        exit 6
    fi
fi

if { [ "$label_required" -eq 1 ] && [ "$label_preexisting" -eq 0 ]; } ||
    { [ "$model_label" != "none" ] && [ "$model_preexisting" -eq 0 ]; }; then
    label_args=("$issue" --repo "$repo")
    [ "$label_required" -eq 0 ] || [ "$label_preexisting" -eq 1 ] || label_args+=(--add-label "$claim_label")
    [ "$model_label" = none ] || [ "$model_preexisting" -eq 1 ] || label_args+=(--add-label "$model_label")
    if ! gh issue edit "${label_args[@]}"; then
        if ! issue_snapshot >"$tmp/issue-after-label.json"; then
            echo "claim transaction: label write is indeterminate; leaving visible markers for recovery" >&2
            exit 6
        fi
        label_state_changed=0
        if [ "$label_required" -eq 1 ] && [ "$label_preexisting" -eq 0 ] &&
            has_label "$tmp/issue-after-label.json" "$claim_label"; then
            label_state_changed=1
        fi
        if [ "$model_label" != none ] && [ "$model_preexisting" -eq 0 ] &&
            has_label "$tmp/issue-after-label.json" "$model_label"; then
            label_state_changed=1
        fi
        if [ "$label_state_changed" -eq 1 ]; then
            echo "claim transaction: label write returned failure and changed marker state has ambiguous provenance" >&2
            exit 6
        fi
        echo "claim transaction: label write failed; leaving visible markers because destructive recovery is unsafe" >&2
        exit 6
    fi
fi

if ! issue_snapshot >"$tmp/issue-before-record.json" || ! has_assignee "$tmp/issue-before-record.json" "$login"; then
    echo "claim transaction: no authenticated assignee backs the record; leaving visible markers because destructive recovery is unsafe" >&2
    exit 6
fi
if ! claim_blockers_absent "$tmp/issue-before-record.json"; then
    echo "claim transaction: a claim blocker appeared before publication; leaving visible markers for recovery" >&2
    exit 6
fi

# A claim is deliberately not a lock, but a stale record must not be published
# after another trusted claim or release has already changed the lineage this
# record was derived from. This narrows the unavoidable API race to the comment
# write itself and, critically, prevents a known-new predecessor from being
# omitted. Marker drift is likewise left visible rather than guessed around.
if ! comments_snapshot >"$tmp/comments-before-record.json" ||
    ! select_predecessor "$tmp/issue-before-record.json" "$tmp/comments-before-record.json" \
        "$tmp/predecessor-before-record.json"; then
    echo "claim transaction: pre-publication lineage is indeterminate; leaving visible markers for recovery" >&2
    exit 6
fi
if ! same_predecessor "$tmp/predecessor.json" "$tmp/predecessor-before-record.json"; then
    echo "claim transaction: a newer trusted claim or release appeared before publication; leaving visible markers for recovery" >&2
    exit 6
fi
if [ "$inherited_continuity_required" -eq 1 ]; then
    if ! timeline_snapshot >"$tmp/timeline-before-record.json" ||
        ! inherited_continuity_holds "$tmp/timeline-before-record.json"; then
        echo "claim transaction: inherited marker continuity changed before publication; leaving visible markers for recovery" >&2
        exit 6
    fi
fi
if { [ "$label_required" -eq 1 ] && ! has_label "$tmp/issue-before-record.json" "$claim_label"; } ||
    { [ "$model_label" != none ] && ! has_label "$tmp/issue-before-record.json" "$model_label"; }; then
    echo "claim transaction: claim markers changed before publication; leaving visible markers for recovery" >&2
    exit 6
fi

comment_command_succeeded=0
if gh issue comment "$issue" --repo "$repo" --body-file "$record_file"; then
    comment_command_succeeded=1
else
    if ! comments_snapshot >"$tmp/comments-after.json"; then
        echo "claim transaction: record publication is indeterminate; leaving visible markers for recovery" >&2
        exit 6
    fi
    exact_record_found=0
    if jq -e --arg login "$login" --rawfile body "$record_file" \
        --slurpfile before "$tmp/comments-before.json" '
        ($body | sub("\\n+$"; "")) as $expected
        | ($before[0] | map(.id)) as $known
        | any(.[];
            .user.login == $login
            and .body == $expected
            and (.id as $id | ($known | index($id)) == null))
    ' "$tmp/comments-after.json" >/dev/null; then
        exact_record_found=1
    fi
    if [ "$exact_record_found" -ne 1 ]; then
        echo "claim transaction: record publication is confirmed absent; leaving visible markers because destructive recovery is unsafe" >&2
        exit 6
    fi
fi

if ! current_record_is_live "$tmp/issue-after-publication.json" "$tmp/comments-current.json" \
    "$tmp/predecessor-after-publication.json" "$tmp/timeline-after-publication.json"; then
    if [ "$comment_command_succeeded" -eq 1 ]; then
        echo "claim transaction: published record is not the current live claim; leaving visible state for recovery" >&2
    else
        echo "claim transaction: exact record was observed but was already superseded or lost required markers" >&2
    fi
    exit 6
fi
[ "$comment_command_succeeded" -eq 1 ] ||
    echo "claim transaction: comment command failed but reconciliation confirmed the exact current record committed" >&2
exit 0
