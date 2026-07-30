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
#   1. Finds the latest `Claiming —` comment on the issue. No claim comment,
#      or a later `Claim released —` comment already superseding it — exit 3.
#   2. Trusts the claim only when its author is the repo owner or a current
#      assignee of the issue. A claim-shaped comment from anyone else is
#      ignored (exit 3): comments are attacker-writable on a public repo, and
#      this script must never let one strip a real assignee.
#   3. Parses the comment's "Claim record" and undoes ONLY what it says the
#      claim added: the `agent:*` label (v1 records name it; a legacy `yes`
#      falls back to every live `agent:*` label), the claim author's own
#      assignment, and — only while the issue is still open — restores a
#      displaced `agent:*` label. A claim with no record at all releases by
#      comment only and touches no marker. Record values are data: labels and
#      logins are validated before they become arguments, never executed.
#   4. Always posts the supersede comment. The comment IS the release — every
#      reader (orient/retro/implement) treats a claim as live until a later
#      `Claim released —` comment supersedes it — so it is posted even when
#      there was no marker left to remove.
#
# Usage:
#   release-claim.sh --repo owner/repo --issue N --reason TEXT [--dry-run]
#
# --reason lands verbatim in the fixed first line:
#   Claim released — <reason>. (Supersedes the claim record above.)
#
# Auth: GH_TOKEN with `issues: write` suffices (assignee and label edits are
# ordinary issue writes). No project scope — this script never touches boards;
# see claim-lifecycle.md for why event-driven Status was declined.
#
# Exit: 0 = released: supersede comment posted, every applicable marker
#           cleared (or fully resolved under --dry-run),
#       1 = the supersede comment failed to post — the release is NOT
#           recorded, whatever markers moved; safe to re-run,
#       2 = usage/environment error, or a trusted claim whose record is
#           present but unreadable — could not verify, fail closed,
#       3 = nothing to do: no claim comment, already superseded, or the
#           claim's author is untrusted (stderr says which). Benign.
#       4 = partial: the comment posted but some marker write failed; the
#           comment says which, so a re-run or a human can finish the job.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --reason TEXT [--dry-run]" >&2
    exit 2
}

repo="${GH_REPO:-}"
issue=""
reason=""
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

# ── Find the claim ───────────────────────────────────────────────────────────
# --paginate --slurp: an array of pages; `add` flattens. The latest `Claiming —`
# comment is the claim; anything after it starting `Claim released —` has
# already superseded it (the same predicate orient/retro/implement read).
# shellcheck disable=SC2016 # single quotes hold a jq program, not shell
if ! claim_json="$(gh api --paginate --slurp "repos/$repo/issues/$issue/comments" |
    jq 'add // []
        | map(select(.body != null))
        | (map(.body | startswith("Claiming —")) | rindex(true)) as $ci
        | if $ci == null then {found: false}
          else {found: true,
                author: .[$ci].user.login,
                body: .[$ci].body,
                superseded: ([.[($ci + 1):][]
                              | select(.body | startswith("Claim released —"))]
                             | length > 0)}
          end')"; then
    echo "could not fetch comments for $repo#$issue — cannot verify, treat as unsafe" >&2
    exit 2
fi

if [ "$(jq -r '.found' <<<"$claim_json")" != "true" ]; then
    echo "$repo#$issue has no claim comment — nothing to release" >&2
    exit 3
fi
if [ "$(jq -r '.superseded' <<<"$claim_json")" = "true" ]; then
    echo "$repo#$issue: latest claim already superseded by a 'Claim released —' comment" >&2
    exit 3
fi
claim_author="$(jq -r '.author // empty' <<<"$claim_json")"

# ── Live issue state (also the trust anchor) ─────────────────────────────────
if ! issue_json="$(gh api "repos/$repo/issues/$issue")"; then
    echo "could not fetch $repo#$issue — cannot verify, treat as unsafe" >&2
    exit 2
fi
issue_state="$(jq -r '.state' <<<"$issue_json")"

trusted=0
if [ "$(lower "$claim_author")" = "$(lower "$owner")" ]; then
    trusted=1
else
    while IFS= read -r a; do
        if [ -n "$a" ] && [ "$(lower "$claim_author")" = "$(lower "$a")" ]; then
            trusted=1
        fi
    done <<<"$(jq -r '.assignees[].login' <<<"$issue_json")"
fi
if [ "$trusted" -ne 1 ]; then
    echo "$repo#$issue: claim comment author '$claim_author' is neither the repo owner nor an assignee — ignoring it" >&2
    exit 3
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
            note "\`$l\` label: removal FAILED — remove it by hand"
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
        note "assignee \`$claim_author\`: removal FAILED — remove it by hand"
    fi
elif [ "$record_present" -eq 1 ]; then
    note "assignee: left in place (the claim record says the claim did not add it, or it is already gone)"
fi

if [ -n "$restore_displaced" ]; then
    if run_write gh issue edit "$issue" --repo "$repo" --add-label "$restore_displaced" >/dev/null; then
        note "displaced label \`$restore_displaced\`: restored"
    else
        marker_failed=1
        note "displaced label \`$restore_displaced\`: restore FAILED — restore it by hand"
    fi
fi
if [ -n "$displaced_note" ]; then
    note "$displaced_note"
fi

if [ "$record_present" -eq 0 ]; then
    note "no claim record survived in the claim comment — markers left untouched; this comment alone records the release"
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

if [ "$marker_failed" -eq 1 ]; then
    echo "$repo#$issue: released with failures — the supersede comment lists what still needs a hand" >&2
    exit 4
fi
echo "$repo#$issue: claim released"
