#!/usr/bin/env bash
# release-claim.sh — release the claim markers a /preflight claim left on an
# issue, from an event instead of a session.
#
# Why: a claim is written by a session, but its release is owed after the
# merge — an event no session is guaranteed to witness (/shepherd stops before
# the merge on policy). Without an event-driven release, every claim whose
# session ends before the human merges strands: the assignee, the `agent:*`
# label, and the claim comment keep advertising an agent mid-flight on work
# that is finished. This script is the release: .github/workflows/
# claim-release.yml runs it on `issues closed` and on `pull_request closed`
# (unmerged), and the backfill runs it by hand. Contract and design record:
# ../references/claim-lifecycle.md.
#
# What it does, in order:
#   1. Reads the issue (state, labels, assignees) — also the trust anchor:
#      only comments authored by the repo owner or a CURRENT assignee count,
#      when selecting the claim AND when deciding it was already released.
#      Comments are attacker-writable on a public repo; a forged `Claiming —`
#      must not shadow the real claim, and a forged `Claim released —` must
#      not suppress its cleanup.
#   2. Finds the latest trusted `Claiming —` comment. None, or a later
#      trusted `Claim released —` already superseding it — exit 3. With
#      --not-after, a claim NEWER than the triggering event also exits 3:
#      replacement work that reclaimed the issue after the event is not this
#      event's to release.
#   3. Parses the comment's "Claim record" and undoes ONLY what it says the
#      claim added: the `agent:*` label (v1 records name it; a legacy `yes`
#      falls back to every live `agent:*` label), the claim author's own
#      assignment, and — only while the issue is still open — restores a
#      displaced `agent:*` label. A claim with no record at all releases by
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
    echo "Usage: $0 --repo owner/repo --issue N --reason TEXT [--not-after ISO8601] [--dry-run]" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
reason=""
not_after=""
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

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

valid_label() {
    case "$1" in
    agent:) return 1 ;;
    *[!a-zA-Z0-9:._-]*) return 1 ;;
    agent:*) return 0 ;;
    *) return 1 ;;
    esac
}

valid_login() {
    case "$1" in
    '' | *[!a-zA-Z0-9-]*) return 1 ;;
    *) return 0 ;;
    esac
}

# ── Live issue state — also the trust anchor ─────────────────────────────────
if ! issue_json="$(gh api "repos/$repo/issues/$issue")"; then
    echo "could not fetch $repo#$issue — cannot verify, treat as unsafe" >&2
    exit 2
fi
issue_state="$(jq -r '.state' <<<"$issue_json")"
# Trusted comment authors: the repo owner plus every CURRENT assignee. An
# attacker cannot self-assign, so a claim- or release-shaped comment from
# anyone else is invisible to the selection below.
trusted_json="$(jq --arg owner "$owner" \
    '[$owner] + [.assignees[].login] | map(ascii_downcase) | unique' \
    <<<"$issue_json")"

# ── Find the claim (trusted comments only) ───────────────────────────────────
# --paginate --slurp: an array of pages; `add` flattens. The latest trusted
# `Claiming —` comment is the claim of record; a later trusted
# `Claim released —` has already superseded it (the same predicate
# orient/retro/implement read). With a cutoff, a claim newer than the
# triggering event refuses (too_new) rather than releasing work the event
# does not cover.
# shellcheck disable=SC2016 # single quotes hold a jq program, not shell
fetch_claim() {
    gh api --paginate --slurp "repos/$repo/issues/$issue/comments" |
        jq --argjson trusted "$trusted_json" --arg cutoff "$not_after" '
            add // []
            | map(select(.body != null)
                  | select((.user.login | ascii_downcase) as $l
                           | $trusted | index($l) != null))
            | (map(.body | startswith("Claiming —")) | rindex(true)) as $ci
            | if $ci == null then {found: false}
              else {found: true,
                    id: .[$ci].id,
                    author: .[$ci].user.login,
                    body: .[$ci].body,
                    too_new: ($cutoff != "" and .[$ci].created_at > $cutoff),
                    superseded: ([.[($ci + 1):][]
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
claim_author="$(jq -r '.author // empty' <<<"$claim_json")"
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
assignee_added=""
label_added=""
label_displaced=""
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
while IFS= read -r line; do
    case "$line" in
    *"Claim record"*) record_present=1 ;;
    *"assignee added by this claim:"*) assignee_added="$(lower "$(extract_value "$line")")" ;;
    *"label added by this claim:"*) label_added="$(extract_value "$line")" ;;
    *"label displaced by this claim:"*) label_displaced="$(extract_value "$line")" ;;
    esac
done <<<"$(jq -r '.body' <<<"$claim_json")"

if [ "$record_present" -eq 1 ]; then
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
    case "$(lower "$label_displaced")" in
    none | '') label_displaced="" ;;
    *)
        if ! valid_label "$label_displaced"; then
            echo "$repo#$issue: claim record names an implausible displaced label ('$label_displaced') — fail closed" >&2
            exit 2
        fi
        ;;
    esac
fi

# ── Decide the marker writes ─────────────────────────────────────────────────
labels_to_remove=""
if [ "$record_present" -eq 1 ]; then
    case "$(lower "$label_added")" in
    no | n/a | none | '') ;;
    yes)
        # Legacy record: it does not say which label, so take the live ones.
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            case "$l" in
            agent:*)
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

remove_assignee=0
if [ "$record_present" -eq 1 ] && [ "$assignee_added" = "yes" ]; then
    if jq -e --arg a "$claim_author" \
        '.assignees[] | select(.login == $a)' <<<"$issue_json" >/dev/null; then
        remove_assignee=1
    fi
fi

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
# show it. A changed claim of record means this event's decision is stale.
if ! recheck_json="$(fetch_claim)"; then
    echo "$repo#$issue: pre-write re-read failed — cannot verify, treat as unsafe" >&2
    exit 2
fi
recheck_id="$(jq -r 'if .found then (.id | tostring) else "" end' <<<"$recheck_json")"
if [ "$recheck_id" != "$claim_id" ] ||
    [ "$(jq -r '.superseded' <<<"$recheck_json")" = "true" ]; then
    echo "$repo#$issue: the claim of record changed between read and write — leaving it for the next event" >&2
    exit 3
fi

# ── Execute ──────────────────────────────────────────────────────────────────
run_write() {
    if [ "$dry_run" -eq 1 ]; then
        echo "DRY-RUN: $*"
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
    note "agent label: none to remove (the claim record says the claim did not add one, or it is already gone)"
fi

if [ "$remove_assignee" -eq 1 ]; then
    if run_write gh issue edit "$issue" --repo "$repo" --remove-assignee "$claim_author" >/dev/null; then
        note "assignee \`$claim_author\`: removed"
    else
        marker_failed=1
        echo "$repo#$issue: failed to remove assignee '$claim_author'" >&2
    fi
elif [ "$record_present" -eq 1 ]; then
    note "assignee: left in place (the claim record says the claim did not add it, or it is already gone)"
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
