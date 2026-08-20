#!/usr/bin/env bash
# release-claim.sh — release the claim markers /claim left on an issue, from
# an event instead of a session.
#
# Why: a claim is written by a session, but its release is owed after the
# merge — an event no session is guaranteed to witness (/shepherd stops before
# the merge on policy). Without an event-driven release, every claim whose
# session ends before the human merges strands: the assignee, the claim label
# (`agent:*` or `claim:*`), and the claim comment keep advertising an agent mid-flight on work
# that is finished. This script is the release: .github/workflows/
# claim-release.yml runs it on `issues closed` and on `pull_request closed`
# (unmerged), and the backfill runs it by hand. Contract and design record:
# ../references/claim-lifecycle.md.
#
# What it does, in order:
# Vocabulary: the live-claim label is migrating from the harness-named
# `agent:*` family (legacy) to the model-centric `claim:*` family
# (`claim:<family>[:<model>]`, e.g. `claim:claude`). This script recognizes
# BOTH during the rolling transition — a claim record may name either, and the
# legacy `yes` fallback sweeps every live `agent:*` AND `claim:*` label.
#
#   1. Reads the issue (state, labels, assignees) and the assignment timeline.
#      A non-owner comment counts only when its current body version was
#      published during a provable assignment interval; owner comments remain
#      trusted directly. Release comments use the automation identity rules.
#      Comments are attacker-writable on a public repo; a forged `Claiming —`
#      must not shadow the real claim, and a forged `Claim released —` must
#      not suppress its cleanup.
#   2. Finds the latest trusted `Claiming —` comment. None, or a later
#      trusted `Claim released —` already superseding it — exit 3. With
#      --not-after, a claim NEWER than the triggering event also exits 3:
#      replacement work that reclaimed the issue after the event is not this
#      event's to release.
#   3. Parses the comment's "Claim record" and undoes ONLY what it says the
#      claim added: the claim label (v1 records name it — `agent:*` or
#      `claim:*`; a legacy `yes` falls back to every live `agent:*`/`claim:*`
#      label), the claim author's own assignment, and — only while the issue
#      is still open — restores a displaced label. A claim with no record at all releases by
#      comment only and touches no marker. Record values are data: labels and
#      logins are validated before they become arguments, never executed.
#   4. Re-reads the comments immediately before writing and aborts (exit 3)
#      if the claim of record changed — the fetch-to-write window is where a
#      concurrent re-claim lands.
#   5. Posts the supersede comment ONLY when every marker write succeeded.
#      The comment IS the release — posting it over a surviving marker would
#      tell every future sweep the claim is settled while stale state
#      remains. A partial release exits 4 with no comment, the Actions job
#      goes red, and a re-run retries the whole release.
#
# Usage:
#   release-claim.sh --repo owner/repo --issue N --reason TEXT
#                    [--not-after ISO8601] [--dry-run]
#
# --reason lands verbatim in the fixed first line:
#   Claim released — <reason>. (Supersedes the claim record above.)
# --not-after is the triggering event's timestamp (e.g. the PR's closed_at):
#   a trusted claim created after it is left alone.
#
# Auth: GH_TOKEN with `issues: write` suffices (assignee and label edits are
# ordinary issue writes). No project scope — this script never touches boards;
# see claim-lifecycle.md for why event-driven Status was declined.
#
# Exit: 0 = released: every applicable marker cleared and the supersede
#           comment posted (or fully resolved under --dry-run),
#       1 = markers cleared but the supersede comment failed to post — the
#           release is NOT recorded; safe to re-run,
#       2 = usage/environment error, or a trusted claim whose record is
#           present but unreadable — could not verify, fail closed,
#       3 = nothing to do: no trusted claim, already superseded, newer than
#           --not-after, or the ground shifted mid-run (stderr says which),
#       4 = partial: a marker write failed; the supersede comment is
#           deliberately NOT posted, so a re-run retries the release instead
#           of reading it as already settled.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --reason TEXT [--not-after ISO8601] [--require-closed] [--branch NAME] [--dry-run]" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
reason=""
not_after=""
require_closed=0
match_branch=""
dry_run=0
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
    --reason)
        [ "$#" -ge 2 ] || usage
        reason="$2"
        shift 2
        ;;
    --not-after)
        [ "$#" -ge 2 ] || usage
        not_after="$2"
        shift 2
        ;;
    --require-closed)
        require_closed=1
        shift
        ;;
    --branch)
        [ "$#" -ge 2 ] || usage
        match_branch="$2"
        shift 2
        ;;
    --dry-run)
        dry_run=1
        shift
        ;;
    -h | --help) usage ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$issue" ] && [ -n "$reason" ] || usage
case "$issue" in
'' | *[!0-9]*)
    echo "--issue must be a number, got: $issue" >&2
    exit 2
    ;;
esac

owner="${repo%%/*}"
name="${repo#*/}"
if [ -z "$owner" ] || [ -z "$name" ] || [ "$owner" = "$repo" ]; then
    echo "--repo must be owner/repo, got: $repo" >&2
    exit 2
fi

for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required but not installed" >&2
        exit 2
    }
done

lineage_tmp="$(mktemp -d)"
trap 'rm -rf "$lineage_tmp"' EXIT

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Accepts both the legacy harness-named family (`agent:*`) and the
# model-centric family (`claim:*`) during the rolling transition; a bare
# prefix with no segment is rejected either way.
valid_label() {
    case "$1" in
    agent: | claim:) return 1 ;;
    *[!a-zA-Z0-9:._-]*) return 1 ;;
    agent:* | claim:*) return 0 ;;
    *) return 1 ;;
    esac
}

valid_model_label() {
    [[ "$1" =~ ^claim:[a-z0-9]+(-[a-z0-9]+)*:[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

model_matches_family_label() {
    model_family="${1%:*}"
    case "$2" in
    claim:*) [ "$model_family" = "$2" ] ;;
    # A legacy alias may be the family marker during migration. Only the fixed
    # pre-registry aliases can prove a model family during event-driven release;
    # a registry-only alias has no trusted snapshot here and therefore fails
    # closed when paired with a model refinement.
    agent:claude-code) [ "$model_family" = claim:claude ] ;;
    agent:codex) [ "$model_family" = claim:gpt ] ;;
    agent:gemini-cli) [ "$model_family" = claim:gemini ] ;;
    agent:kimi-k2) [ "$model_family" = claim:kimi ] ;;
    agent:qwen-code) [ "$model_family" = claim:qwen ] ;;
    agent:*) return 1 ;;
    no | n/a | none | '')
        # A claim may own a model refinement while its required family marker
        # predates the chain. The family is then validation context, not a
        # cleanup target: require that exact marker to remain live.
        jq -e --arg family "$model_family" \
            'any(.labels[]?; .name == $family)' <<<"$issue_json" >/dev/null
        ;;
    *) return 1 ;;
    esac
}

valid_login() {
    case "$1" in
    '' | *[!a-zA-Z0-9-]*) return 1 ;;
    *) return 0 ;;
    esac
}

fetch_timeline() {
    gh api --paginate --slurp "repos/$repo/issues/$issue/timeline" | jq 'add // []'
}

timeline_well_formed() {
    jq -e '
        type == "array"
        and all(.[];
            if .event == "assigned" or .event == "unassigned" then
                (.created_at | type == "string"
                    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
                and (.assignee.login | type == "string")
            elif .event == "unlabeled" then
                (.created_at | type == "string"
                    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
                and (.label.name | type == "string")
            else true
            end)
    ' <<<"$1" >/dev/null
}

# ── Live issue state ─────────────────────────────────────────────────────────
if ! issue_json="$(gh api "repos/$repo/issues/$issue")"; then
    echo "could not fetch $repo#$issue — cannot verify, treat as unsafe" >&2
    exit 2
fi
issue_state="$(jq -r '.state' <<<"$issue_json")"
# A queued issues-closed event whose issue was reopened before this ran is
# stale: an accidental close/reopen continues the existing claim, and
# releasing it would strip active work.
if [ "$require_closed" -eq 1 ] && [ "$issue_state" != "closed" ]; then
    echo "$repo#$issue is open again — the triggering close event is stale, leaving the claim" >&2
    exit 3
fi
# Trusted CLAIM authors: the repo owner plus every CURRENT assignee — and in
# either case only with write-shaped author_association (OWNER, MEMBER, or
# COLLABORATOR, checked per comment in fetch_claim): a maintainer can assign
# an outside commenter without granting write access, and assignment alone
# must not let that commenter steer a write-capable token. RELEASE comments
# additionally trust github-actions[bot] — this script's own supersede
# comments are authored by it under a workflow's GITHUB_TOKEN, and a re-run
# that could not see them would release the same claim twice.
trusted_json="$(jq --arg owner "$owner" \
    '[$owner] + [.assignees[].login] | map(ascii_downcase) | unique' \
    <<<"$issue_json")"
if ! lineage_timeline="$(fetch_timeline)"; then
    echo "$repo#$issue: claim timeline is unreadable — cannot prove historical claimant trust" >&2
    exit 2
fi
if ! timeline_well_formed "$lineage_timeline"; then
    echo "$repo#$issue: claim timeline is malformed — cannot prove historical claimant trust" >&2
    exit 2
fi

# ── Find the claim (trusted comments only) ───────────────────────────────────
# --paginate --slurp: an array of pages; `add` flattens. The latest trusted
# `Claiming —` comment is the claim of record; a later trusted
# `Claim released —` has already superseded it (the same predicate
# kickoff/retro/implement read). With a cutoff, a claim newer than the
# triggering event refuses (too_new) rather than releasing work the event
# does not cover.
# shellcheck disable=SC2016 # single quotes hold a jq program, not shell
fetch_claim() {
    gh api --paginate --slurp "repos/$repo/issues/$issue/comments" |
        jq --argjson trusted "$trusted_json" \
            --argjson timeline "$lineage_timeline" \
            --arg owner "$owner" \
            --arg cutoff "$not_after" '
            def dl: (.user.login | ascii_downcase);
            def writeauth:
                (.author_association // "") as $a
                | (["OWNER", "MEMBER", "COLLABORATOR"] | index($a)) != null;
            def trusted_claimant:
                (dl as $l | $trusted | index($l) != null) and writeauth;
            def assigned_through_claim_version:
                dl as $login
                | .updated_at as $version_time
                | ([ $timeline[]
                     | select(.event == "assigned"
                              and (.assignee.login | ascii_downcase) == $login
                              and .created_at < $version_time) ]
                   | last // null) as $assignment
                | $assignment != null
                and ([ $timeline[]
                       | select(.event == "unassigned"
                                and (.assignee.login | ascii_downcase) == $login
                                and .created_at >= $assignment.created_at
                                and .created_at <= $version_time) ]
                     | length == 0);
            def historical_claimant:
                writeauth
                and dl != "github-actions[bot]"
                and (dl == ($owner | ascii_downcase) or assigned_through_claim_version);
            def trusted_release:
                (.body | startswith("Claim released —"))
                and (trusted_claimant or dl == "github-actions[bot]");
            add // []
            | map(select(.body != null))
            # Historical claims remain lineage evidence after a partial retry
            # removes their assignee only when the timeline proves that the
            # author remained assigned through the current body version.
            | map(select(trusted_claimant
                         or trusted_release
                         or ((.body | startswith("Claiming —")) and historical_claimant))) as $events
            | ($events
               | map((.body | startswith("Claiming —")) and historical_claimant)
               | rindex(true)) as $ci
            | if $ci == null then {found: false}
              else ([range(0; $ci) as $i
                     | select($events[$i] | trusted_release)
                     | $i] | last // -1) as $release_before
              | ([range($release_before + 1; $ci) as $i
                  | select($events[$i]
                           | ((.body | startswith("Claiming —")) and historical_claimant))
                  | $i] | last // null) as $pi
              | {found: true,
                    id: $events[$ci].id,
                    created: ($events[$ci].created_at // ""),
                    updated: ($events[$ci].updated_at // ""),
                    author: $events[$ci].user.login,
                    body: $events[$ci].body,
                    predecessor:
                        (if $pi == null then null
                         else {id: $events[$pi].id,
                               updated: ($events[$pi].updated_at // ""),
                               author: $events[$pi].user.login,
                               body: $events[$pi].body}
                         end),
                    lineage:
                        ([range($release_before + 1; $ci + 1) as $i
                          | select($events[$i]
                                   | ((.body | startswith("Claiming —"))
                                      and (historical_claimant or $i == $ci)))
                          | {id: $events[$i].id,
                             created: ($events[$i].created_at // ""),
                             updated: ($events[$i].updated_at // ""),
                             author: $events[$i].user.login,
                             body: $events[$i].body}]),
                    too_new: ($cutoff != "" and $events[$ci].created_at >= $cutoff),
                    superseded: ([$events[($ci + 1):][]
                                  | select(.body
                                           | startswith("Claim released —"))]
                                 | length > 0)}
              end'
}

if ! claim_json="$(fetch_claim)"; then
    echo "could not fetch comments for $repo#$issue — cannot verify, treat as unsafe" >&2
    exit 2
fi

if [ "$(jq -r '.found' <<<"$claim_json")" != "true" ]; then
    echo "$repo#$issue has no trusted claim comment — nothing to release" >&2
    exit 3
fi
if [ "$(jq -r '.superseded' <<<"$claim_json")" = "true" ]; then
    echo "$repo#$issue: latest claim already superseded by a 'Claim released —' comment" >&2
    exit 3
fi
if [ "$(jq -r '.too_new' <<<"$claim_json")" = "true" ]; then
    echo "$repo#$issue: the latest claim postdates the triggering event (--not-after $not_after) — it belongs to newer work, leaving it" >&2
    exit 3
fi
claim_id="$(jq -r '.id' <<<"$claim_json")"
claim_created="$(jq -er '.created | select(type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' \
    <<<"$claim_json")" || {
    echo "$repo#$issue: claim timestamp is unreadable — cannot prove marker continuity" >&2
    exit 2
}
claim_author="$(jq -r '.author // empty' <<<"$claim_json")"
claim_lineage_fingerprint="$(jq -c '[.lineage[] | {id, updated}]' <<<"$claim_json")"
claim_author_was_live=0
if jq -e --arg a "$(lower "$claim_author")" \
    'any(.assignees[]?; (.login | ascii_downcase) == $a)' <<<"$issue_json" >/dev/null; then
    claim_author_was_live=1
fi

# With --branch (the unmerged-PR path), release only the claim that PR owns:
# the claim's first line names its branch, and a claim for a different
# branch — replacement work claimed before the obsolete PR was closed, say —
# is not this event's to release. Compared as data, exact equality only.
if [ -n "$match_branch" ]; then
    claim_first="$(jq -r '.body' <<<"$claim_json" | head -n 1)"
    claim_branch=""
    case "$claim_first" in
    *"on branch "*)
        claim_branch="${claim_first#*on branch }"
        claim_branch="${claim_branch%% (session*}"
        ;;
    esac
    if [ -z "$claim_branch" ] || [ "$claim_branch" != "$match_branch" ]; then
        echo "$repo#$issue: claim of record is for branch '${claim_branch:-unknown}', not '$match_branch' — this close does not own it" >&2
        exit 3
    fi
fi
if ! valid_login "$claim_author"; then
    echo "$repo#$issue: claim author '$claim_author' is not a plausible login — refusing to act on it" >&2
    exit 2
fi

# ── Parse the claim record ───────────────────────────────────────────────────
# Line-anchored on the shared literal "by this claim:" — the keys carry
# backticks and their own colons, so never split on a colon. Values are the
# first token after the anchor, stripped of backticks/quotes and any trailing
# clause ("n/a, repo has no such label" -> "n/a"). Contract:
# ../references/claim-lifecycle.md.
record_present=0
saw_assignee=0
saw_label=0
saw_model_label=0
saw_displaced=0
saw_chain_assignee_set=0
saw_chain_assignee=0
saw_chain_assignee_login=0
saw_chain_label=0
saw_chain_model_label=0
saw_chain_displaced=0
assignee_added=""
label_added=""
model_label_added=""
label_displaced=""
chain_assignee_set=""
chain_assignee_owned=""
chain_assignee_login=""
chain_label_owned=""
chain_model_label_owned=""
chain_label_displaced=""
direct_assignee_added="no"
direct_model_label_added=""
owned_assignees_file="$lineage_tmp/owned-assignees"
omitted_assignees_file="$lineage_tmp/omitted-assignees"
: >"$owned_assignees_file"
: >"$omitted_assignees_file"
extract_value() {
    v="${1#*by this claim:}"
    v="${v%%,*}"
    v="${v//\`/}"
    v="${v//\"/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v%% *}"
    printf '%s' "$v"
}
extract_chain_value() {
    v="${1#*claim chain:}"
    v="${v%%,*}"
    v="${v//\`/}"
    v="${v//\"/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v%% *}"
    printf '%s' "$v"
}

line_value() {
    v="${1#*claim chain:}"
    v="${v#*by this claim:}"
    v="${v//\`/}"
    v="${v//\"/}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

optional_body_value() {
    local prefix="$1" body="$2"
    awk -v prefix="$prefix" '
        index($0, prefix) == 1 { count++; value = substr($0, length(prefix) + 1) }
        END {
            if (count > 1 || (count == 1 && value == "")) exit 2
            if (count == 1) print value
        }
    ' <<<"$body"
}

canonical_login_set() {
    local value="$1"
    [ "$value" != none ] || return 0
    jq -er --arg value "$value" '
        ($value | split(",")) as $items
        | select(($items | length) > 0 and ($items | length) <= 10)
        | select(all($items[];
            test("^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)*$")
            and . == ascii_downcase))
        | select(($items | sort | unique | join(",")) == $value)
        | $items[]
    ' <<<'null'
}

# v3 writers use the canonical comma form above. During the dependency branch's
# review window, bounded whitespace-separated v3 records were emitted; accept
# those as a read-only transition without allowing new comma records to relax
# canonical ordering or case.
read_login_set() {
    local value="$1" normalized count login
    if [[ "$value" == *,* ]] || [ "$value" = none ]; then
        canonical_login_set "$value"
        return
    fi
    normalized=""
    count=0
    for login in $value; do
        valid_login "$login" && [ "$login" = "$(lower "$login")" ] || return 1
        count=$((count + 1))
        [ "$count" -le 10 ] || return 1
        printf '%s\n' "$normalized" | grep -Fxq "$login" && return 1
        normalized="${normalized}${normalized:+$'\n'}$login"
    done
    [ "$count" -gt 0 ] || return 1
    printf '%s\n' "$normalized" | sort
}

set_has() {
    grep -Fxq "$2" "$1"
}

# Validate the complete trusted claim run, oldest to newest. A v3 leaf may
# retain only targets proven by its immediate predecessor and may add only its
# own direct assignment. Older scalar records are accepted, but their target
# must pass the same proof; their predecessor set is retained instead of being
# discarded by the retired direct-ownership-outranks-inheritance rule.
prove_assignee_lineage() {
    local lineage_json="$1" count i body author direct set_value old_owned old_login target
    local proven="$lineage_tmp/proven" next="$lineage_tmp/next" candidate="$lineage_tmp/candidate"
    : >"$proven"
    count="$(jq '.lineage | length' <<<"$lineage_json")"
    i=0
    while [ "$i" -lt "$count" ]; do
        body="$(jq -r --argjson i "$i" '.lineage[$i].body' <<<"$lineage_json")"
        author="$(jq -r --argjson i "$i" '.lineage[$i].author | ascii_downcase' <<<"$lineage_json")"
        valid_login "$author" || return 1
        if ! direct="$(optional_body_value '- assignee added by this claim: ' "$body")"; then
            return 1
        fi
        direct="$(lower "$(line_value "$direct")")"
        case "$direct" in yes | no) ;; *) return 1 ;; esac

        if ! set_value="$(optional_body_value '- assignee logins owned by this claim chain: ' "$body")"; then
            return 1
        fi
        if [ -n "$set_value" ]; then
            set_value="$(line_value "$set_value")"
            if ! read_login_set "$set_value" >"$candidate"; then
                return 1
            fi
            while IFS= read -r target; do
                [ -n "$target" ] || continue
                set_has "$proven" "$target" || { [ "$direct" = yes ] && [ "$target" = "$author" ]; } || return 1
            done <"$candidate"
            if [ "$direct" = yes ] && ! set_has "$candidate" "$author"; then
                return 1
            fi
            while IFS= read -r target; do
                [ -n "$target" ] || continue
                if ! set_has "$candidate" "$target" &&
                    jq -e --arg a "$target" 'any(.assignees[]?; (.login | ascii_downcase) == $a)' \
                        <<<"$issue_json" >/dev/null; then
                    return 1
                fi
                if ! set_has "$candidate" "$target"; then
                    printf '%s\n' "$target" >>"$omitted_assignees_file"
                fi
            done <"$proven"
            sort -u "$candidate" >"$next"
            mv "$next" "$proven"
            i=$((i + 1))
            continue
        fi

        if ! old_owned="$(optional_body_value '- assignee owned by this claim chain: ' "$body")" ||
            ! old_login="$(optional_body_value '- assignee login owned by this claim chain: ' "$body")"; then
            return 1
        fi
        : >"$next"
        if [ -n "$old_owned" ] || [ -n "$old_login" ]; then
            old_owned="$(lower "$(line_value "$old_owned")")"
            old_login="$(lower "$(line_value "$old_login")")"
            case "$old_owned" in
            yes)
                [ -n "$old_login" ] || old_login="$author"
                [ "$old_login" != none ] && valid_login "$old_login" || return 1
                if ! set_has "$proven" "$old_login"; then
                    [ "$direct" = yes ] && [ "$old_login" = "$author" ] || return 1
                fi
                cat "$proven" >"$next"
                ;;
            no)
                [ -z "$old_login" ] || [ "$old_login" = none ] || return 1
                ;;
            *) return 1 ;;
            esac
        fi
        [ "$direct" = yes ] && printf '%s\n' "$author" >>"$next"
        sort -u "$next" >"$proven"
        i=$((i + 1))
    done
    cat "$proven"
}

# Prove family/model cleanup targets across the same trusted lineage. A leaf
# may retain only the predecessor's proven target or initialize ownership with
# the exact label that leaf directly added.
prove_label_lineage() {
    local lineage_json="$1" count i body direct direct_model chain chain_model proven proven_model
    proven=""
    proven_model=""
    count="$(jq '.lineage | length' <<<"$lineage_json")"
    i=0
    while [ "$i" -lt "$count" ]; do
        body="$(jq -r --argjson i "$i" '.lineage[$i].body' <<<"$lineage_json")"
        direct="$(optional_body_value '- `claim:` label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- claim: label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- `agent:` label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- agent: label added by this claim: ' "$body")" || return 1
        direct="$(line_value "$direct")"
        direct_model="$(optional_body_value '- `claim:` model label added by this claim: ' "$body")" || return 1
        [ -n "$direct_model" ] || direct_model="$(optional_body_value '- claim: model label added by this claim: ' "$body")" || return 1
        chain="$(optional_body_value '- `claim:` label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- claim: label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- `agent:` label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- agent: label owned by this claim chain: ' "$body")" || return 1
        chain="$(line_value "$chain")"
        chain_model="$(optional_body_value '- `claim:` model label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain_model" ] || chain_model="$(optional_body_value '- claim: model label owned by this claim chain: ' "$body")" || return 1

        # Legacy `yes` proves that its own release may sweep then-live labels,
        # but names no exact target a later structured record may inherit.
        case "$(lower "$direct")" in yes | no | n/a | none | '') direct="" ;; *) valid_label "$direct" || return 1 ;; esac
        case "$(lower "$direct_model")" in no | n/a | none | '') direct_model="" ;; *) valid_model_label "$direct_model" || return 1 ;; esac
        if [ -n "$chain" ]; then
            case "$(lower "$chain")" in
            no | n/a | none) proven="" ;;
            *)
                valid_label "$chain" || return 1
                { [ "$chain" = "$proven" ] || [ "$chain" = "$direct" ]; } || return 1
                proven="$chain"
                ;;
            esac
        else
            proven="$direct"
        fi
        if [ -n "$chain_model" ]; then
            case "$(lower "$chain_model")" in
            no | n/a | none) proven_model="" ;;
            *)
                valid_model_label "$chain_model" || return 1
                { [ "$chain_model" = "$proven_model" ] || [ "$chain_model" = "$direct_model" ]; } || return 1
                model_matches_family_label "$chain_model" "$proven" || return 1
                proven_model="$chain_model"
                ;;
            esac
        else
            proven_model="$direct_model"
        fi
        i=$((i + 1))
    done
    printf '%s\n%s\n' "${proven:-none}" "${proven_model:-none}"
}

# Prove the one displaced-label hand-back target across the same lineage. Old
# direct-only records remain readable, but every structured record must either
# carry the already-proven target unchanged or initialize it by displacing the
# immediate predecessor's proven owned label.
prove_displaced_lineage() {
    local lineage_json="$1" count i body direct chain direct_displaced chain_displaced
    local prior_owned proven_owned proven_displaced expected
    proven_owned=""
    proven_displaced=""
    count="$(jq '.lineage | length' <<<"$lineage_json")"
    i=0
    while [ "$i" -lt "$count" ]; do
        body="$(jq -r --argjson i "$i" '.lineage[$i].body' <<<"$lineage_json")"
        direct="$(optional_body_value '- `claim:` label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- claim: label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- `agent:` label added by this claim: ' "$body")" || return 1
        [ -n "$direct" ] || direct="$(optional_body_value '- agent: label added by this claim: ' "$body")" || return 1
        direct="$(line_value "$direct")"
        chain="$(optional_body_value '- `claim:` label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- claim: label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- `agent:` label owned by this claim chain: ' "$body")" || return 1
        [ -n "$chain" ] || chain="$(optional_body_value '- agent: label owned by this claim chain: ' "$body")" || return 1
        direct_displaced="$(optional_body_value '- `claim:` label displaced by this claim: ' "$body")" || return 1
        [ -n "$direct_displaced" ] || direct_displaced="$(optional_body_value '- claim: label displaced by this claim: ' "$body")" || return 1
        [ -n "$direct_displaced" ] || direct_displaced="$(optional_body_value '- `agent:` label displaced by this claim: ' "$body")" || return 1
        [ -n "$direct_displaced" ] || direct_displaced="$(optional_body_value '- agent: label displaced by this claim: ' "$body")" || return 1
        chain_displaced="$(optional_body_value '- `claim:` label displaced by this claim chain: ' "$body")" || return 1
        [ -n "$chain_displaced" ] || chain_displaced="$(optional_body_value '- claim: label displaced by this claim chain: ' "$body")" || return 1
        [ -n "$chain_displaced" ] || chain_displaced="$(optional_body_value '- `agent:` label displaced by this claim chain: ' "$body")" || return 1
        [ -n "$chain_displaced" ] || chain_displaced="$(optional_body_value '- agent: label displaced by this claim chain: ' "$body")" || return 1

        prior_owned="$proven_owned"
        case "$(lower "$direct")" in yes | no | n/a | none | '') direct="" ;; *) valid_label "$direct" || return 1 ;; esac
        if [ -n "$chain" ]; then
            chain="$(line_value "$chain")"
            case "$(lower "$chain")" in
            no | n/a | none) proven_owned="" ;;
            *)
                valid_label "$chain" || return 1
                { [ "$chain" = "$prior_owned" ] || [ "$chain" = "$direct" ]; } || return 1
                proven_owned="$chain"
                ;;
            esac
        else
            proven_owned="$direct"
        fi

        direct_displaced="$(line_value "$direct_displaced")"
        case "$(lower "$direct_displaced")" in
        none | '') direct_displaced="" ;;
        *) valid_label "$direct_displaced" || return 1 ;;
        esac
        if [ -n "$chain_displaced" ]; then
            chain_displaced="$(line_value "$chain_displaced")"
            case "$(lower "$chain_displaced")" in
            none) chain_displaced="" ;;
            *) valid_label "$chain_displaced" || return 1 ;;
            esac
            expected="$proven_displaced"
            if [ -n "$direct_displaced" ]; then
                [ "$direct_displaced" = "$prior_owned" ] || return 1
                [ -z "$expected" ] || [ "$expected" = "$direct_displaced" ] || return 1
                expected="$direct_displaced"
            fi
            [ "$chain_displaced" = "$expected" ] || return 1
            proven_displaced="$chain_displaced"
        else
            # Direct-only legacy records predate structured chain proof. Keep
            # their established reader behavior without letting a structured
            # successor invent or replace the target.
            proven_displaced="$direct_displaced"
        fi
        i=$((i + 1))
    done
    printf '%s\n' "${proven_displaced:-none}"
}

# A trusted recordless claim is an ownership boundary, not malformed
# structured provenance. The transaction that follows it cannot inherit any
# cleanup target from it, so release proves only the structured suffix after
# the last such boundary. This preserves strict proof inside that suffix while
# keeping legacy recordless refreshes releasable.
structured_lineage_suffix() {
    jq '
        def has_record_heading:
            any(.body | split("\n")[];
                . == "Claim record (for `/wrap` — undo only what this claim added):");
        .lineage as $lineage
        | ([range(0; $lineage | length) as $i
            | select(($lineage[$i] | has_record_heading) | not)
            | $i] | last // -1) as $boundary
        | .lineage = $lineage[($boundary + 1):]
    ' <<<"$1"
}

# Optional harness/model/family/runtime-environment/session lines are
# operational metadata only. They are deliberately ignored here: release
# authority comes solely from the required "by this claim" fields below, and
# legacy records omit the metadata entirely.
while IFS= read -r line; do
    case "$line" in
    'Claim record (for `/wrap` — undo only what this claim added):') record_present=1 ;;
    *"assignee added by this claim:"*)
        saw_assignee=1
        assignee_added="$(lower "$(extract_value "$line")")"
        ;;
    *"model label added by this claim:"*)
        saw_model_label=1
        model_label_added="$(extract_value "$line")"
        ;;
    *"label added by this claim:"*)
        saw_label=1
        label_added="$(extract_value "$line")"
        ;;
    *"label displaced by this claim:"*)
        saw_displaced=1
        label_displaced="$(extract_value "$line")"
        ;;
    *"assignee logins owned by this claim chain:"*)
        saw_chain_assignee_set=1
        chain_assignee_set="$(line_value "$line")"
        ;;
    *"assignee owned by this claim chain:"*)
        saw_chain_assignee=1
        chain_assignee_owned="$(lower "$(extract_chain_value "$line")")"
        ;;
    *"assignee login owned by this claim chain:"*)
        saw_chain_assignee_login=1
        chain_assignee_login="$(extract_chain_value "$line")"
        ;;
    *"model label owned by this claim chain:"*)
        saw_chain_model_label=1
        chain_model_label_owned="$(extract_chain_value "$line")"
        ;;
    *"label owned by this claim chain:"*)
        saw_chain_label=1
        chain_label_owned="$(extract_chain_value "$line")"
        ;;
    *"label displaced by this claim chain:"*)
        saw_chain_displaced=1
        chain_label_displaced="$(extract_chain_value "$line")"
        ;;
    esac
done <<<"$(jq -r '.body' <<<"$claim_json")"

if [ "$record_present" -eq 1 ]; then
    # Keep the leaf's direct ownership separate from inherited chain ownership:
    # a cross-account takeover can legitimately own both assignments.
    direct_assignee_added="$assignee_added"
    direct_model_label_added="$model_label_added"
    # A record with a missing or truncated field is unreadable provenance,
    # not a no-op: releasing around it would clear some markers, leave
    # others, and then a supersede comment would block every retry.
    if [ "$saw_assignee" -ne 1 ] || [ "$saw_label" -ne 1 ] || [ "$saw_displaced" -ne 1 ]; then
        echo "$repo#$issue: claim record present but incomplete (missing field lines) — fail closed" >&2
        exit 2
    fi
    if [ -z "$assignee_added" ] || [ -z "$label_added" ] || [ -z "$label_displaced" ]; then
        echo "$repo#$issue: claim record present but a field has no value — fail closed" >&2
        exit 2
    fi
    case "$assignee_added" in
    yes | no) ;;
    *)
        echo "$repo#$issue: claim record present but its assignee line is unreadable ('$assignee_added') — fail closed" >&2
        exit 2
        ;;
    esac
    case "$(lower "$label_added")" in
    yes | no | n/a | none | '') ;;
    *)
        if ! valid_label "$label_added"; then
            echo "$repo#$issue: claim record names an implausible label ('$label_added') — fail closed" >&2
            exit 2
        fi
        ;;
    esac
    if [ "$saw_model_label" -ne "$saw_chain_model_label" ]; then
        echo "$repo#$issue: claim record has incomplete model-label ownership — fail closed" >&2
        exit 2
    fi
    case "$(lower "$model_label_added")" in
    no | n/a | none | '') ;;
    *)
        valid_model_label "$model_label_added" || {
            echo "$repo#$issue: claim record names an implausible model label ('$model_label_added') — fail closed" >&2
            exit 2
        }
        ;;
    esac
    case "$(lower "$label_displaced")" in
    none | '') label_displaced="" ;;
    *)
        if ! valid_label "$label_displaced"; then
            echo "$repo#$issue: claim record names an implausible displaced label ('$label_displaced') — fail closed" >&2
            exit 2
        fi
        ;;
    esac
    chain_record=0
    if [ "$saw_chain_assignee_set" -ne 0 ]; then
        chain_record=1
        if [ "$saw_chain_assignee_set" -ne 1 ] || [ -z "$chain_assignee_set" ] ||
            [ "$saw_chain_assignee" -gt 1 ] || [ "$saw_chain_assignee_login" -ne 0 ] ||
            [ "$saw_chain_label" -ne 1 ] || [ "$saw_chain_displaced" -ne 1 ] ||
            { [ "$saw_model_label" -eq 1 ] && [ "$saw_chain_model_label" -ne 1 ]; }; then
            echo "$repo#$issue: claim record has incomplete or mixed claim-chain ownership — fail closed" >&2
            exit 2
        fi
        if ! read_login_set "$chain_assignee_set" >/dev/null; then
            echo "$repo#$issue: claim-chain assignee set is unreadable ('$chain_assignee_set') — fail closed" >&2
            exit 2
        fi
        if [ "$saw_chain_assignee" -eq 1 ]; then
            case "$chain_assignee_owned:$chain_assignee_set" in
            yes:none | no:none) expected_chain_owned=no ;;
            yes:*) expected_chain_owned=yes ;;
            *)
                echo "$repo#$issue: transitional claim-chain assignee scalar disagrees with its set — fail closed" >&2
                exit 2
                ;;
            esac
            [ "$chain_assignee_owned" = "$expected_chain_owned" ] || {
                echo "$repo#$issue: transitional claim-chain assignee scalar disagrees with its set — fail closed" >&2
                exit 2
            }
        fi
    elif [ "$saw_chain_assignee" -ne 0 ] || [ "$saw_chain_assignee_login" -ne 0 ] ||
        [ "$saw_chain_label" -ne 0 ] || [ "$saw_chain_model_label" -ne 0 ] || [ "$saw_chain_displaced" -ne 0 ]; then
        chain_record=1
        if [ "$saw_chain_assignee" -ne 1 ] || [ "$saw_chain_label" -ne 1 ] || [ "$saw_chain_displaced" -ne 1 ] ||
            [ -z "$chain_assignee_owned" ] || [ -z "$chain_label_owned" ] || [ -z "$chain_label_displaced" ]; then
            echo "$repo#$issue: claim record has incomplete claim-chain ownership — fail closed" >&2
            exit 2
        fi
        case "$chain_assignee_owned" in yes | no) ;; *)
            echo "$repo#$issue: claim-chain assignee ownership is unreadable ('$chain_assignee_owned') — fail closed" >&2
            exit 2
            ;;
        esac
        if [ "$saw_chain_assignee_login" -ne 0 ]; then
            if [ "$saw_chain_assignee_login" -ne 1 ] || [ -z "$chain_assignee_login" ] ||
                { [ "$chain_assignee_owned" = yes ] && { [ "$chain_assignee_login" = none ] || ! valid_login "$chain_assignee_login"; }; } ||
                { [ "$chain_assignee_owned" = no ] && [ "$chain_assignee_login" != none ]; }; then
                echo "$repo#$issue: claim-chain assignee login is unreadable ('$chain_assignee_login') — fail closed" >&2
                exit 2
            fi
        fi
    fi
    if [ "$chain_record" -eq 1 ]; then
        case "$(lower "$chain_label_owned")" in
        no | n/a | none) ;;
        *)
            if ! valid_label "$chain_label_owned"; then
                echo "$repo#$issue: claim-chain ownership names an implausible label ('$chain_label_owned') — fail closed" >&2
                exit 2
            fi
            ;;
        esac
        case "$(lower "$chain_label_displaced")" in
        none) chain_label_displaced="" ;;
        *)
            if ! valid_label "$chain_label_displaced"; then
                echo "$repo#$issue: claim-chain displaced label is implausible ('$chain_label_displaced') — fail closed" >&2
                exit 2
            fi
            ;;
        esac
        case "$(lower "$chain_model_label_owned")" in
        no | n/a | none | '') ;;
        *)
            if ! valid_model_label "$chain_model_label_owned" ||
                ! model_matches_family_label "$chain_model_label_owned" "$chain_label_owned"; then
                echo "$repo#$issue: claim-chain ownership names an implausible model label ('$chain_model_label_owned') — fail closed" >&2
                exit 2
            fi
            ;;
        esac
        # The current leaf, not its author, owns inherited provenance. This is
        # what makes a crashed-session takeover release predecessor markers.
        label_added="$chain_label_owned"
        model_label_added="$chain_model_label_owned"
        label_displaced="$chain_label_displaced"
    fi

    case "$(lower "$direct_model_label_added")" in
    no | n/a | none | '') ;;
    *)
        if ! model_matches_family_label "$direct_model_label_added" "$label_added"; then
            echo "$repo#$issue: direct model label does not refine its owned family label — fail closed" >&2
            exit 2
        fi
        ;;
    esac

    if [ "$chain_record" -eq 1 ]; then
        proof_claim_json="$(structured_lineage_suffix "$claim_json")"
        if ! prove_assignee_lineage "$proof_claim_json" >"$owned_assignees_file"; then
            echo "$repo#$issue: inherited assignee targets lack unambiguous predecessor provenance — fail closed" >&2
            exit 2
        fi
        if ! proven_labels="$(prove_label_lineage "$proof_claim_json")"; then
            echo "$repo#$issue: inherited label targets lack unambiguous predecessor provenance — fail closed" >&2
            exit 2
        fi
        if ! proven_displaced="$(prove_displaced_lineage "$proof_claim_json")"; then
            echo "$repo#$issue: displaced-label target lacks unambiguous predecessor provenance — fail closed" >&2
            exit 2
        fi
        expected_proven_label="$label_added"
        expected_proven_model="$model_label_added"
        case "$(lower "$expected_proven_label")" in no | n/a | none | '') expected_proven_label=none ;; esac
        case "$(lower "$expected_proven_model")" in no | n/a | none | '') expected_proven_model=none ;; esac
        [ "$(sed -n '1p' <<<"$proven_labels")" = "$expected_proven_label" ] &&
            [ "$(sed -n '2p' <<<"$proven_labels")" = "$expected_proven_model" ] || {
            echo "$repo#$issue: current label cleanup targets do not match proven lineage — fail closed" >&2
            exit 2
        }
        expected_proven_displaced="${label_displaced:-none}"
        [ "$proven_displaced" = "$expected_proven_displaced" ] || {
            echo "$repo#$issue: current displaced-label target does not match proven lineage — fail closed" >&2
            exit 2
        }
    elif [ "$direct_assignee_added" = yes ]; then
        printf '%s\n' "$(lower "$claim_author")" >"$owned_assignees_file"
    fi
fi

# ── Decide the marker writes ─────────────────────────────────────────────────
labels_to_remove=""
if [ "$record_present" -eq 1 ]; then
    case "$(lower "$label_added")" in
    no | n/a | none | '') ;;
    yes)
        # Legacy record: it does not say which label, so take the live ones —
        # both vocabularies, since a `yes` record predates the rename and the
        # live label could be either family.
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
            agent:* | claim:*)
                if valid_label "$l"; then
                    labels_to_remove="$labels_to_remove$l"$'\n'
                fi
                ;;
            esac
        done <<<"$(jq -r '.labels[].name' <<<"$issue_json")"
        ;;
    *)
        # v1 record names the label; remove it only if it is still applied.
        if jq -e --arg l "$label_added" '.labels[] | select(.name == $l)' \
            <<<"$issue_json" >/dev/null; then
            labels_to_remove="$label_added"$'\n'
        fi
        ;;
    esac
fi

for owned_model_label in "$direct_model_label_added" "$model_label_added"; do
    case "$(lower "$owned_model_label")" in
    no | n/a | none | '') continue ;;
    esac
    if jq -e --arg l "$owned_model_label" '.labels[] | select(.name == $l)' \
        <<<"$issue_json" >/dev/null &&
        ! printf '%s' "$labels_to_remove" | grep -Fqx "$owned_model_label"; then
        labels_to_remove="$labels_to_remove$owned_model_label"$'\n'
    fi
done

assignees_to_remove="$lineage_tmp/assignees-to-remove"
: >"$assignees_to_remove"
while IFS= read -r owned; do
    [ -n "$owned" ] || continue
    if jq -e --arg a "$owned" 'any(.assignees[]?; (.login | ascii_downcase) == $a)' \
        <<<"$issue_json" >/dev/null; then
        printf '%s\n' "$owned" >>"$assignees_to_remove"
    fi
done <"$owned_assignees_file"

restore_displaced=""
displaced_note=""
if [ -n "$label_displaced" ]; then
    if [ "$issue_state" = "open" ]; then
        restore_displaced="$label_displaced"
    else
        # Restoring another agent's label onto a closed issue would recreate
        # the exact stale-marker state this release exists to remove.
        displaced_note="skipped restoring \`$label_displaced\` — the issue is closed"
    fi
fi

# ── Re-bind the claim immediately before writing ─────────────────────────────
# The fetch-to-write window is where a concurrent re-claim lands, and the
# markers converge (same account, same label), so only the comment stream can
# show it. Order matters: re-read the ISSUE first — a close-then-reopen would
# sneak past --require-closed judged on the first read, and an unassignment
# changes who is trusted — then rebuild the trust list from that fresh read,
# and only then re-bind the claim under it. Compared on id AND updated_at:
# an EDITED claim comment keeps its id, and acting on the stale body parsed
# earlier would honour a record its author just corrected.
if ! recheck_issue="$(gh api "repos/$repo/issues/$issue")"; then
    echo "$repo#$issue: pre-write issue re-read failed — cannot verify, treat as unsafe" >&2
    exit 2
fi
if [ "$(jq -r '.state' <<<"$recheck_issue")" != "$issue_state" ]; then
    echo "$repo#$issue: issue state changed between read and write — leaving it for the next event" >&2
    exit 3
fi
trusted_json="$(jq --arg owner "$owner" \
    '[$owner] + [.assignees[].login] | map(ascii_downcase) | unique' \
    <<<"$recheck_issue")"
if ! lineage_timeline="$(fetch_timeline)"; then
    echo "$repo#$issue: pre-write timeline is unreadable — cannot prove claim lineage" >&2
    exit 2
fi
if ! timeline_well_formed "$lineage_timeline"; then
    echo "$repo#$issue: pre-write timeline is malformed — cannot prove claim lineage" >&2
    exit 2
fi
if ! recheck_json="$(fetch_claim)"; then
    echo "$repo#$issue: pre-write re-read failed — cannot verify, treat as unsafe" >&2
    exit 2
fi
recheck_id="$(jq -r 'if .found then (.id | tostring) else "" end' <<<"$recheck_json")"
recheck_updated="$(jq -r '.updated // ""' <<<"$recheck_json")"
claim_updated="$(jq -r '.updated // ""' <<<"$claim_json")"
if [ "$recheck_id" != "$claim_id" ] ||
    [ "$recheck_updated" != "$claim_updated" ] ||
    [ "$(jq -c '[.lineage[] | {id, updated}]' <<<"$recheck_json")" != "$claim_lineage_fingerprint" ] ||
    [ "$(jq -r '.superseded' <<<"$recheck_json")" = "true" ]; then
    echo "$repo#$issue: the claim of record changed between read and write — leaving it for the next event" >&2
    exit 3
fi
if [ "$claim_author_was_live" -eq 1 ] &&
    [ "$(lower "$claim_author")" != "$(lower "$owner")" ] &&
    ! jq -e --arg a "$(lower "$claim_author")" \
        'any(.assignees[]?; (.login | ascii_downcase) == $a)' <<<"$recheck_issue" >/dev/null; then
    echo "$repo#$issue: the current claimant was unassigned between read and write — leaving it for the next event" >&2
    exit 3
fi
while IFS= read -r omitted; do
    [ -n "$omitted" ] || continue
    if jq -e --arg a "$omitted" 'any(.assignees[]?; (.login | ascii_downcase) == $a)' \
        <<<"$recheck_issue" >/dev/null; then
        echo "$repo#$issue: an omitted predecessor assignee became live before write — leaving it for the next event" >&2
        exit 3
    fi
done < <(sort -u "$omitted_assignees_file")

# Marker presence plus comment lineage cannot distinguish continuous ownership
# from a removal followed by an independent same-value re-add. Immediately
# before destructive writes, prove that every assignee/family/model cleanup
# target stayed uninterrupted since the current trusted leaf committed. The
# transaction producer proves inherited continuity up to that leaf; this check
# extends the same invariant from the leaf to cleanup time.
marker_continuous_since_leaf() {
    local kind="$1" marker="$2" timeline="$3"
    jq -e --arg kind "$kind" --arg marker "$(lower "$marker")" --arg since "$claim_created" '
        all(.[];
            if $kind == "assignee" and .event == "unassigned"
                and (.assignee.login | ascii_downcase) == $marker then
                .created_at < $since
            elif $kind == "label" and .event == "unlabeled"
                and (.label.name | ascii_downcase) == $marker then
                .created_at < $since
            else true
            end)
    ' <<<"$timeline" >/dev/null
}

if [ -s "$assignees_to_remove" ] || [ -n "$labels_to_remove" ]; then
    cleanup_timeline="$lineage_timeline"
    while IFS= read -r cleanup_assignee; do
        [ -n "$cleanup_assignee" ] || continue
        if ! marker_continuous_since_leaf assignee "$cleanup_assignee" "$cleanup_timeline"; then
            echo "$repo#$issue: assignee '$cleanup_assignee' lacks uninterrupted ownership through cleanup — leaving markers untouched" >&2
            exit 3
        fi
    done <"$assignees_to_remove"
    while IFS= read -r cleanup_label; do
        [ -n "$cleanup_label" ] || continue
        if ! marker_continuous_since_leaf label "$cleanup_label" "$cleanup_timeline"; then
            echo "$repo#$issue: label '$cleanup_label' lacks uninterrupted ownership through cleanup — leaving markers untouched" >&2
            exit 3
        fi
    done <<<"$labels_to_remove"
fi

# ── Execute ──────────────────────────────────────────────────────────────────
run_write() {
    if [ "$dry_run" -eq 1 ]; then
        # To stderr: callers redirect the wrapped command's stdout to
        # /dev/null, which would swallow the plan line this exists to show.
        echo "DRY-RUN: $*" >&2
        return 0
    fi
    "$@"
}

marker_failed=0
released_lines=""
note() { released_lines="$released_lines- $1"$'\n'; }

if [ -n "$labels_to_remove" ]; then
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        if run_write gh issue edit "$issue" --repo "$repo" --remove-label "$l" >/dev/null; then
            note "\`$l\` label: removed"
        else
            marker_failed=1
            echo "$repo#$issue: failed to remove label '$l'" >&2
        fi
    done <<<"$labels_to_remove"
elif [ "$record_present" -eq 1 ]; then
    note "claim label: none to remove (the claim record says the claim did not add one, or it is already gone)"
fi

if [ -n "$restore_displaced" ]; then
    if run_write gh issue edit "$issue" --repo "$repo" --add-label "$restore_displaced" >/dev/null; then
        note "displaced label \`$restore_displaced\`: restored"
    else
        marker_failed=1
        echo "$repo#$issue: failed to restore displaced label '$restore_displaced'" >&2
    fi
fi
if [ -n "$displaced_note" ]; then
    note "$displaced_note"
fi

# Assignee LAST among the marker writes, so a failed earlier write leaves the
# assignment in place. Once assignee removal succeeds, a retry can still trust
# the exact historical claim body through its proven assignment interval; do
# not manufacture a new assignment interval as compensation.
assignee_order="$lineage_tmp/assignee-order"
claim_author_lower="$(lower "$claim_author")"
{
    grep -Fvx "$claim_author_lower" "$assignees_to_remove" || true
    grep -Fx "$claim_author_lower" "$assignees_to_remove" || true
} >"$assignee_order"
if [ -s "$assignee_order" ]; then
    while IFS= read -r assignee_to_remove; do
        [ -n "$assignee_to_remove" ] || continue
        if [ "$marker_failed" -eq 1 ]; then
            note "assignee \`$assignee_to_remove\`: left in place — an earlier write failed and an assignment keeps the retry trusted"
        elif run_write gh issue edit "$issue" --repo "$repo" --remove-assignee "$assignee_to_remove" >/dev/null; then
            note "assignee \`$assignee_to_remove\`: removed"
        else
            marker_failed=1
            echo "$repo#$issue: failed to remove assignee '$assignee_to_remove'" >&2
        fi
    done <"$assignee_order"
elif [ "$record_present" -eq 1 ]; then
    note "assignee: left in place (the proven ownership set is empty or its members are already gone)"
fi

if [ "$record_present" -eq 0 ]; then
    note "no claim record survived in the claim comment — markers left untouched; this comment alone records the release"
fi

# The supersede comment is posted ONLY when every marker write succeeded: a
# release comment over a surviving marker reads as settled to every sweep,
# and a re-run would exit 3 instead of retrying the failed write.
if [ "$marker_failed" -eq 1 ]; then
    echo "$repo#$issue: partial release — supersede comment withheld; re-run to retry the failed writes" >&2
    exit 4
fi

body="Claim released — $reason. (Supersedes the claim record above.)

Released by claim-release automation:
$released_lines"

if [ "$dry_run" -eq 1 ]; then
    echo "DRY-RUN: gh issue comment $issue --repo $repo --body-file - <<BODY"
    printf '%s\n' "$body"
    echo "BODY"
elif ! printf '%s\n' "$body" | gh issue comment "$issue" --repo "$repo" --body-file - >/dev/null; then
    echo "$repo#$issue: failed to post the supersede comment — the release is NOT recorded; re-run to retry" >&2
    exit 1
fi

echo "$repo#$issue: claim released"
