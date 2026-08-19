#!/usr/bin/env bash
# triage-report.sh — find and upsert the triage skill's single rolling report
# issue.
#
# The triage skill labels what it may label and reports everything else here:
# stale claims, blocked-without-reason, aging needs-* states, closed-completed
# issues with unticked criteria, duplicate closes missing pointers, title
# violations, tier/method proposals. One rolling issue, not a stream — re-runs
# UPSERT it: the body is regenerated from the current scan every run, so an
# entry for a resolved problem disappears on the next run and re-runs are
# idempotent (same findings in, byte-identical body out — the timestamp is
# injectable for tests via TRIAGE_NOW).
#
# Identity and safety:
#   - The report issue is identified by a stable HTML-comment marker in its
#     body, not by memory of a number. `find` locates it; `sync` re-verifies
#     the marker on the live body immediately before editing and REFUSES to
#     edit any issue that lacks it — this script can never rewrite an ordinary
#     issue's body. (The triage never-list forbids body edits on triaged
#     issues; the report issue is the skill's own artifact and the one
#     exception, which is why the marker check is hard.)
#   - The scan excludes the report issue from triage (self-exclusion), so the
#     report can never enter its own findings.
#
# Entries-file contract (written by the model, validated here): each per-issue
# entry is a `### #<n> — ...` heading whose NEXT line is the entry key
# `<!-- triage-entry:<n> -->`. Aggregate sections (title-violation sweeps and
# other backlog-wide notes) use `## ` headings and are not keyed. A malformed
# entries file is refused rather than published.
#
# Usage:
#   triage-report.sh find --repo owner/repo [--title TITLE]
#   triage-report.sh sync --repo owner/repo --entries-file PATH
#                    [--title TITLE] [--execute]
#
# `find` prints the open report issue's number, or "none". Dry-run is sync's
# DEFAULT: it prints the target action and the assembled body without writing.
# --execute additionally requires TRIAGE_EXECUTE=1 in the environment (set by
# the `task triage` wrapper for supervised runs).
#
# Exit: 0 = ok (found/none, applied, or dry-run resolved cleanly)
#       1 = the write failed
#       2 = usage/environment error, malformed entries file, or an ambiguous
#           report (two open issues carry the marker — resolve by hand)
#       4 = refused: the target issue's live body no longer carries the marker
set -euo pipefail

MARKER='<!-- harmon-triage-report -->'
DEFAULT_TITLE='(triage): Track backlog findings'
asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
title_module_dir="$asset_dir/../../issue-title-support/assets"

usage() {
    echo "Usage: $0 find --repo owner/repo [--title TITLE]" >&2
    echo "       $0 sync --repo owner/repo --entries-file PATH" >&2
    echo "            [--title TITLE] [--execute]" >&2
    exit 2
}

die() {
    local code="$1"
    shift
    echo "triage-report: $*" >&2
    exit "$code"
}

validate_title() {
    local title="$1" rc=0
    [ -r "$title_module_dir/issue-title.jq" ] ||
        die 2 "shared issue-title predicate is missing"
    jq -e -n -L "$title_module_dir" --arg value "$title" \
        'include "issue-title"; $value | issue_title_valid' \
        >/dev/null 2>&1 || rc=$?
    case "$rc" in
    0) ;;
    1) die 2 "report title violates the canonical scoped-title contract" ;;
    *) die 2 "could not evaluate the shared issue-title predicate" ;;
    esac
}

# Print the open report issue's number, or nothing. Dies on ambiguity.
#
# The marker alone is forgeable — any issue author can paste it. The invariant
# is that report identity must be unforgeable by untrusted authors yet stable
# across every legitimate operator, so candidates are filtered by
# `author_association`: only OWNER/MEMBER/COLLABORATOR-authored issues
# qualify. A stranger's marker-carrying issue can neither become the report
# nor block the real one, and a report created by any trusted operator stays
# visible to all of them.
find_report() {
    local repo="$1" candidates matches="" n assoc count=0
    candidates="$(gh issue list --repo "$repo" --state open --limit 1000 \
        --json number,body -q \
        "[.[] | select(.body | contains(\"$MARKER\")) | .number] | .[]")" ||
        die 2 "could not list open issues of $repo"
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        assoc="$(gh api "repos/$repo/issues/$n" \
            -q .author_association </dev/null)" ||
            die 2 "could not verify the author of marker candidate #$n"
        case "$assoc" in
        OWNER | MEMBER | COLLABORATOR)
            matches="$matches$n"$'\n'
            count=$((count + 1))
            ;;
        *) ;; # untrusted author's forged marker — ignored
        esac
    done <<<"$candidates"
    [ "$count" -le 1 ] ||
        die 2 "ambiguous: $count open issues carry the report marker" \
            "($(printf '%s' "$matches" | tr '\n' ' ')) — close the extras first"
    printf '%s' "${matches%$'\n'}"
}

cmd_find() {
    local repo=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --title)
            # Accepted for symmetry; identity is the marker, not the title.
            [ "$#" -ge 2 ] || usage
            shift 2
            ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] || usage
    local found
    found="$(find_report "$repo")"
    if [ -n "$found" ]; then echo "$found"; else echo "none"; fi
}

# Validate the entries file: every `### #<n>` heading's next line must be the
# matching `<!-- triage-entry:<n> -->` key.
validate_entries() {
    local file="$1" lineno=0 pending="" line
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        if [ -n "$pending" ]; then
            printf '%s' "$line" | grep -q "^<!-- triage-entry:${pending} -->$" ||
                die 2 "malformed entries file: heading for #$pending (line" \
                    "$((lineno - 1))) is not followed by <!-- triage-entry:$pending -->"
            pending=""
            continue
        fi
        if printf '%s' "$line" | grep -qE '^### #[0-9]+'; then
            pending="$(printf '%s' "$line" | sed -E 's/^### #([0-9]+).*/\1/')"
        fi
    done <"$file"
    [ -z "$pending" ] ||
        die 2 "malformed entries file: heading for #$pending has no entry key"
}

cmd_sync() {
    local repo="" entries="" title="$DEFAULT_TITLE" execute=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --entries-file)
            [ "$#" -ge 2 ] || usage
            entries="$2"
            shift 2
            ;;
        --title)
            [ "$#" -ge 2 ] || usage
            title="$2"
            shift 2
            ;;
        --execute) execute=1 && shift ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$entries" ] || usage
    validate_title "$title"
    # Same run-binding as triage-apply.sh: a mismatched --repo is refused.
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$repo" != "$TRIAGE_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$TRIAGE_REPO'"
    fi
    [ -f "$entries" ] || die 2 "entries file not found: $entries"
    # When the wrapper bound a scratch directory, the entries file must live
    # inside it: the worker's Write grant is scoped there, so any path outside
    # is a prompt-injected attempt to publish an arbitrary readable file
    # (a key, a config) into a GitHub issue body.
    if [ -n "${TRIAGE_SCRATCH:-}" ]; then
        local entries_abs
        entries_abs="$(cd "$(dirname "$entries")" && pwd)/$(basename "$entries")" ||
            die 2 "could not resolve the entries file path"
        case "$entries_abs" in
        "$TRIAGE_SCRATCH"/*) ;;
        *) die 4 "refused: --entries-file must live under this run's" \
            "scratch directory ($TRIAGE_SCRATCH)" ;;
        esac
    fi
    validate_entries "$entries"

    local now body entries_content
    now="${TRIAGE_NOW:-$(date -u '+%Y-%m-%d %H:%M UTC')}"
    # GitHub caps issue bodies at 65,536 characters, and a large backlog can
    # legitimately produce more. Truncate at a section boundary with a loud
    # note rather than letting the write fail after labels already applied —
    # a stale-but-present report beats an update that errors out.
    local budget=60000
    if [ "$(wc -c <"$entries")" -gt "$budget" ]; then
        entries_content="$(awk -v b="$budget" '
            {n += length($0) + 1
             if (n > b && ($0 ~ /^### #/ || $0 ~ /^## /)) exit
             print}' "$entries")"
        # The awk pass cuts at section boundaries; a single section larger
        # than the whole budget would pass through intact, so hard-cap the
        # result as a fallback. Pure bash substring — a printf|head pipeline
        # here dies of SIGPIPE under pipefail exactly when the cap triggers.
        if [ "${#entries_content}" -gt "$budget" ]; then
            entries_content="${entries_content:0:$budget}"
        fi
        entries_content="$entries_content

## Report truncated

This run produced more findings than fit in one issue body. Everything
below the last section above was omitted — re-run after resolving some
entries, or triage a narrower window."
    elif [ -s "$entries" ]; then
        entries_content="$(cat "$entries")"
    else
        entries_content="No findings this run."
    fi
    body="$(
        printf '%s\n\n' "$MARKER"
        printf '%s\n' \
            "Rolling triage report — regenerated by the triage skill on every" \
            'run (`task triage`). Entries describe the *current* backlog:' \
            'resolve the underlying issue and the entry disappears on the next' \
            'run. Do not hand-edit; anything below is overwritten.' \
            '' \
            "_Last generated: ${now}_" \
            ''
        printf '%s\n' "$entries_content"
    )"

    local target
    target="$(find_report "$repo")"

    if [ "$execute" -eq 0 ]; then
        if [ -n "$target" ]; then
            echo "DRY-RUN would normalize the title and edit the body of $repo#$target"
        else
            echo "DRY-RUN would create '$title' in $repo"
        fi
        echo "DRY-RUN body follows:"
        printf '%s\n' "$body"
        return 0
    fi

    [ "${TRIAGE_EXECUTE:-0}" = "1" ] ||
        die 2 "--execute requires TRIAGE_EXECUTE=1 in the environment" \
            "(set by the task triage wrapper for supervised runs)"

    if [ -n "$target" ]; then
        # Re-verify the marker on the LIVE body immediately before the edit —
        # the one write this script makes must be provably aimed at its own
        # artifact, whatever changed since `find`.
        local live_json live live_title
        live_json="$(gh issue view "$target" --repo "$repo" --json body,title)" ||
            die 2 "could not re-read $repo#$target before editing"
        live="$(printf '%s' "$live_json" | jq -r '.body // ""')" ||
            die 2 "could not parse the live report body"
        live_title="$(printf '%s' "$live_json" | jq -r '.title // ""')" ||
            die 2 "could not parse the live report title"
        printf '%s' "$live" | grep -qF "$MARKER" ||
            die 4 "refused: $repo#$target no longer carries the report marker"
        # Idempotency: identical findings must not churn the issue. The
        # timestamp line is generation metadata, so compare without it and
        # skip the edit when nothing else changed.
        if [ "$live_title" = "$title" ] &&
            [ "$(printf '%s\n' "$body" | grep -v '^_Last generated: ')" = \
                "$(printf '%s\n' "$live" | grep -v '^_Last generated: ')" ]; then
            echo "no content change — skipping edit of $repo#$target"
            return 0
        fi
        printf '%s\n' "$body" |
            gh issue edit "$target" --repo "$repo" --title "$title" \
                --body-file - >/dev/null ||
            die 1 "write failed: gh issue edit $repo#$target"
        echo "APPLIED report update to $repo#$target"
    else
        local created
        created="$(printf '%s\n' "$body" |
            gh issue create --repo "$repo" --title "$title" \
                --body-file -)" ||
            die 1 "write failed: gh issue create in $repo"
        echo "APPLIED report creation in $repo: $created"
    fi
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
find) cmd_find "$@" ;;
sync) cmd_sync "$@" ;;
*) usage ;;
esac
