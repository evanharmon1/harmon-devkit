#!/usr/bin/env bash
# triage-report.sh — find and upsert the triage skill's single rolling report
# issue.
#
# The triage skill labels what it may label and reports everything else here:
# stale claims, blocked-without-reason, aging needs-* states, closed-completed
# issues with unticked criteria, duplicate closes missing pointers, title
# violations, possible-completion candidates (an open issue whose delivery
# looks finished), human-label refusals, guarded human removals (or planned
# removals in dry-run) with reasons and retained candidates, tier/method proposals. One rolling issue,
# not a stream — re-runs
# UPSERT it: the body is regenerated from the current scan every run, so an
# entry for a resolved problem disappears on the next run and re-runs are
# idempotent (same findings in, byte-identical body out — the timestamp is
# injectable for tests via TRIAGE_NOW).
#
# Size: the body is budgeted to 60,000 bytes, under GitHub's 65,536-character
# limit. Other entries are truncated to fit; human-removal records are never
# dropped, because they cannot be reconstructed once labels change. When they
# alone exceed the budget they are split into parts, all posted as comments
# on the report issue before the body is written, and the body points at
# them. Each part is keyed by a digest of the run's removal records, so a
# re-run of the same entries file posts no part twice. More than 10 parts is
# refused before any write, with the records printed.
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
    if jq -e -n -L "$title_module_dir" --arg value "$title" \
        'include "issue-title"; $value | issue_title_warn' >/dev/null 2>&1; then
        echo "triage-report: warning: report title exceeds 100 code-point soft limit" >&2
    fi
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
            grep -q "^<!-- triage-entry:${pending} -->$" <<<"$line" ||
                die 2 "malformed entries file: heading for #$pending (line" \
                    "$((lineno - 1))) is not followed by <!-- triage-entry:$pending -->"
            pending=""
            continue
        fi
        if grep -qE '^### #[0-9]+' <<<"$line"; then
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
    # Removal evidence cannot be reconstructed after labels change. Render it
    # first and reserve its bytes before truncating any other report entries.
    local removal_content other_content budget=60000 removal_size remaining_budget
    local partition='
        /^## / {section = ($0 == "## Human removals"); keep = section}
        /^### #/ {keep = section || ($0 ~ /human (removed|removal planned|removal unconfirmed):/)}
        keep == wanted {print}'
    removal_content="$(awk -v wanted=1 "$partition" "$entries")"
    other_content="$(awk -v wanted=0 "$partition" "$entries")"
    removal_size="$(printf '%s' "$removal_content" | wc -c)"
    # Removal records that do not fit in one body never live in the body at
    # all: they are split into parts of at most `budget` bytes, every part is
    # posted as a comment on the report issue (post_removal_parts) before the
    # body is written, and the body only points at them. Comments are
    # append-only, so a later failed write cannot take a record back. Each
    # comment is keyed by a digest of this run's removal records and its part
    # number, so a re-run of the same entries file posts nothing twice.
    # Parts are capped at max_parts: a larger run is refused before any write
    # (its records are printed) rather than flooding the report issue.
    removal_parts=0 removal_digest="" parts_dir=""
    local max_parts=10
    if [ "$removal_size" -gt "$budget" ]; then
        parts_dir="$(mktemp -d)"
        trap 'rm -rf "$parts_dir"' EXIT
        removal_parts="$(printf '%s\n' "$removal_content" |
            split_parts "$budget" "$parts_dir")" ||
            die 2 "could not split the removal records into parts"
        if [ "$removal_parts" -gt "$max_parts" ]; then
            printf '%s\n' "$removal_content" >&2
            die 2 "refused: this run's removal records need $removal_parts" \
                "report comments, over the cap of $max_parts — they are" \
                "printed above; nothing was written"
        fi
        removal_digest="$(printf '%s' "$removal_content" | digest)" ||
            die 2 "could not digest the removal records"
        removal_content="## Human removals

This run's removal records do not fit in one issue body. All $removal_parts parts
are comments on this issue, each starting with
\`<!-- harmon-triage-removals:$removal_digest:<part>/$removal_parts -->\`."
        removal_size="$(printf '%s' "$removal_content" | wc -c)"
    fi
    remaining_budget=$((budget - removal_size))
    [ -z "$removal_content" ] || remaining_budget=$((remaining_budget - 2))
    if [ "$(printf '%s' "$other_content" | wc -c)" -gt "$remaining_budget" ]; then
        if [ "$remaining_budget" -le 0 ]; then
            other_content=""
        else
            other_content="$(awk -v b="$remaining_budget" '
                {n += length($0) + 1
                 if (n > b && ($0 ~ /^### #/ || $0 ~ /^## /)) exit
                 print}' <<<"$other_content")"
            # A single oversized non-removal section needs a hard-cap fallback.
            if [ "${#other_content}" -gt "$remaining_budget" ]; then
                other_content="${other_content:0:$remaining_budget}"
            fi
        fi
        other_content="$other_content

## Report truncated

This run produced more findings than fit in one issue body. Other entries
below the last retained section were omitted — re-run after resolving some
entries, or triage a narrower window. Human removal records are retained in full."
    fi
    if [ -n "$removal_content" ]; then
        entries_content="$removal_content"
        [ -z "$other_content" ] || entries_content="$entries_content

$other_content"
    elif [ -n "$other_content" ]; then
        entries_content="$other_content"
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
        local i
        for ((i = 1; i <= removal_parts; i++)); do
            echo "DRY-RUN would post removal part $i/$removal_parts as a comment; it follows:"
            removal_part_comment "$i"
        done
        return 0
    fi

    [ "${TRIAGE_EXECUTE:-0}" = "1" ] ||
        die 2 "--execute requires TRIAGE_EXECUTE=1 in the environment" \
            "(set by the task triage wrapper for supervised runs)"

    if [ -n "$target" ]; then
        # Re-verify the marker on the LIVE body immediately before the edit —
        # the one write this script makes must be provably aimed at its own
        # artifact, whatever changed since `find`.
        local live_json live live_title is_bot
        live_json="$(gh issue view "$target" --repo "$repo" --json body,title,author)" ||
            die 2 "could not re-read $repo#$target before editing"
        live="$(printf '%s' "$live_json" | jq -r '.body // ""')" ||
            die 2 "could not parse the live report body"
        live_title="$(printf '%s' "$live_json" | jq -r '.title // ""')" ||
            die 2 "could not parse the live report title"
        grep -qF "$MARKER" <<<"$live" ||
            die 4 "refused: $repo#$target no longer carries the report marker"

        is_bot="$(printf '%s' "$live_json" | jq -r '
            if (.author.type == "Bot")
               or (.author.is_bot == true)
               or (.author.login == "app/renovate")
               or (.author.login // "" | test("^app/|\\[bot\\]$"))
            then "true" else "false" end')" ||
            die 2 "could not check author of $repo#$target"
        if [ "$is_bot" = "true" ]; then
            die 4 "refused: will not retitle bot-authored issue $repo#$target"
        fi
        # The removal parts go first: comments are append-only, so a later
        # failure cannot take back a part already posted, and the body that
        # points at them is written only once they exist.
        post_removal_parts "$repo" "$target"
        # Idempotency: identical findings must not churn the issue. The
        # timestamp line is generation metadata, so compare without it and
        # skip the edit when nothing else changed.
        if [ "$live_title" = "$title" ] &&
            [ "$(printf '%s\n' "$body" | grep -v '^_Last generated: ')" = \
                "$(printf '%s\n' "$live" | grep -v '^_Last generated: ')" ]; then
            echo "no content change — skipping edit of $repo#$target"
        else
            printf '%s\n' "$body" |
                gh issue edit "$target" --repo "$repo" --title "$title" \
                    --body-file - >/dev/null || {
                dump_body
                die 1 "write failed: gh issue edit $repo#$target"
            }
            echo "APPLIED report update to $repo#$target"
        fi
    else
        # A new report issue must exist before its comments can. With removal
        # parts to post, it is created with a placeholder body, so no body
        # ever points at comments that are not there yet; the real body is
        # written once every part is posted.
        local created create_body="$body"
        [ "$removal_parts" -eq 0 ] || create_body="$(
            printf '%s\n\n' "$MARKER"
            printf '%s\n' "Rolling triage report — being written: this run's" \
                "removal records are being posted as comments. If this text" \
                "remains, the run failed partway and printed what it could not post."
        )"
        created="$(printf '%s\n' "$create_body" |
            gh issue create --repo "$repo" --title "$title" \
                --body-file -)" || {
            dump_body
            dump_parts_from 1
            die 1 "write failed: gh issue create in $repo"
        }
        echo "APPLIED report creation in $repo: $created"
        if [ "$removal_parts" -gt 0 ]; then
            post_removal_parts "$repo" "${created##*/}"
            printf '%s\n' "$body" |
                gh issue edit "${created##*/}" --repo "$repo" \
                    --body-file - >/dev/null || {
                dump_body
                die 1 "write failed: gh issue edit $repo#${created##*/}"
            }
            echo "APPLIED report body to $repo#${created##*/}"
        fi
    fi
}

# Removal records cannot be rebuilt once labels change, and a supervised run
# discards its scratch entries file on exit. So whatever this run could not
# write is printed to stderr, where the operator still has it.
dump_body() {
    echo "triage-report: the report body was NOT written; it follows so its" \
        "removal records are not lost:" >&2
    printf '%s\n' "$body" >&2
}

dump_parts_from() {
    local i
    [ "$removal_parts" -ge "$1" ] || return 0
    echo "triage-report: removal parts $1–$removal_parts were NOT posted; they" \
        "follow so they are not lost:" >&2
    for ((i = $1; i <= removal_parts; i++)); do
        removal_part_comment "$i" >&2
        echo >&2
    done
}

# split_parts BUDGET DIR — split stdin into DIR/part-1..N of at most BUDGET
# bytes each, breaking between lines (a single line longer than BUDGET is cut
# inside it). Prints N.
split_parts() {
    LC_ALL=C awk -v b="$1" -v dir="$2" '
        function next_part() { close(f); part++; f = dir "/part-" part; len = 0 }
        BEGIN { part = 1; f = dir "/part-1"; len = 0; printf "" > f }
        {
            line = $0 "\n"
            if (len > 0 && len + length(line) > b) next_part()
            while (length(line) > b) {
                printf "%s", substr(line, 1, b) > f
                line = substr(line, b + 1)
                next_part()
            }
            printf "%s", line > f
            len += length(line)
        }
        END { close(f); print part }'
}

digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -c1-16
    else
        shasum -a 256 | cut -c1-16
    fi
}

removal_part_marker() {
    printf '<!-- harmon-triage-removals:%s:%s/%s -->' \
        "$removal_digest" "$1" "$removal_parts"
}

removal_part_comment() {
    removal_part_marker "$1"
    printf '\n\n## Human removals (part %s of %s)\n\n' "$1" "$removal_parts"
    cat "$parts_dir/part-$1"
}

# post_removal_parts REPO ISSUE — post removal parts 1..N as comments on the
# report issue, skipping any a trusted author already posted with the same
# marker (a re-run of the same entries file posts nothing twice, and completes
# one that failed partway). On a failure, the parts not posted are printed.
post_removal_parts() {
    local repo="$1" issue="$2" existing i
    [ "$removal_parts" -gt 0 ] || return 0
    if ! existing="$(gh api "repos/$repo/issues/$issue/comments" --paginate -q '
        .[] | select(.author_association == "OWNER"
                     or .author_association == "MEMBER"
                     or .author_association == "COLLABORATOR") | .body')"; then
        dump_parts_from 1
        die 1 "write incomplete: could not list the comments of $repo#$issue," \
            "so its removal parts were not posted"
    fi
    for ((i = 1; i <= removal_parts; i++)); do
        if grep -qF "$(removal_part_marker "$i")" <<<"$existing"; then
            echo "removal part $i/$removal_parts is already on $repo#$issue"
            continue
        fi
        if ! removal_part_comment "$i" |
            gh issue comment "$issue" --repo "$repo" --body-file - >/dev/null; then
            dump_parts_from "$i"
            die 1 "write failed: removal part $i/$removal_parts on $repo#$issue;" \
                "the records not posted are printed above"
        fi
        echo "APPLIED removal part $i/$removal_parts as a comment on $repo#$issue"
    done
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
find) cmd_find "$@" ;;
sync) cmd_sync "$@" ;;
*) usage ;;
esac
