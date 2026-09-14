#!/usr/bin/env bash
# groom-verdicts.sh — validate fan-out subagent verdict files against the
# fixed groom vocabulary (issue #1015) and join them into one dispositions
# dataset for groom-report.sh. Writes nothing to GitHub, ever.
#
# Each subagent writes ONE JSON Lines file: one object per line, one line per
# issue it verified. Required fields on every row: number, verdict, priority,
# reason, evidence, group. verdict must be exactly one of CLOSE-done,
# CLOSE-obsolete, CLOSE-wrong-repo (target), KEEP, NEEDS-DECISION, NEEDS-INFO,
# or the pattern CLOSE-dup-of-#<N>. priority must be high, medium, or low.
# Every CLOSE-* verdict requires a nonempty `evidence` field (file:line,
# merged PR, or commit — never a comment). NEEDS-DECISION additionally
# requires a nonempty `question` field, phrased as one sentence.
#
# Usage:
#   groom-verdicts.sh validate FILE...
#   groom-verdicts.sh join --repo owner/repo --scan PATH --out PATH
#                          [--allow-missing] [--proposals PATH] FILE...
#
# `validate` only checks the vocabulary/evidence contract, printing every
# violation it finds (never stopping at the first) and exiting 1 if any row is
# invalid. `join` validates the same way, then checks COVERAGE against the
# scan's open-issue list before merging (challenge round 1 finding 3):
#   - a number with more than one verdict row (duplicate) — always refused
#   - a verdict row whose number is not in scan.open (unknown) — always
#     refused
#   - an open issue with no verdict row at all (missing) — refused unless
#     --allow-missing, in which case the numbers are written to
#     stats.unverified and the report shows an "Unverified" list instead of
#     silently shipping an incomplete dataset
# join then merges every surviving row with the matching open issue from the
# scan dataset (title, bot_owned, age) and computes the summary stats
# groom-report.sh renders. `join` with ZERO verdict FILEs is accepted only
# when scan.open is itself empty (a clean backlog produces a clean empty
# dataset instead of a hard failure — finding 4); it is refused otherwise.
#
# --proposals PATH (optional) is a JSON file of the fan-out subagents'
# collected parent/milestone regrouping proposals (finding 9):
#   {"parents":[{"parent":N|null,"title":"...","children":[N,...]}],
#    "milestones":[{"action":"close|rename|widen|create","title":"...",
#                    "new_title":"...","issues":[N,...]}]}
# carried into the dataset verbatim as `proposals` for groom-report.sh's
# Parent issues / Milestones sections to render.
#
# Exit: 0 = valid (validate) / dataset written (join), 1 = a row violates the
#       vocabulary contract, or coverage finds a duplicate/unknown/unallowed-
#       missing number (each names the offending issue number(s)), 2 = usage.
set -euo pipefail

usage() {
    echo "Usage: $0 validate FILE..." >&2
    echo "       $0 join --repo owner/repo --scan PATH --out PATH" >&2
    echo "               [--allow-missing] [--proposals PATH] FILE..." >&2
    exit 2
}

die() {
    echo "groom-verdicts: $*" >&2
    exit 2
}

# CLOSE-wrong-repo carries a real target description in its parens (e.g.
# "CLOSE-wrong-repo (harmonops/harmon-infra)"), per references/verdict-
# vocabulary.md and references/subagent-brief.md — a literal word "target"
# is the placeholder in the docs, not a value to match verbatim.
CLOSE_RE='^CLOSE-(done|obsolete|wrong-repo \([^)]+\)|dup-of-#[0-9]+)$'
VERDICT_RE='^(CLOSE-done|CLOSE-obsolete|CLOSE-wrong-repo \([^)]+\)|CLOSE-dup-of-#[0-9]+|KEEP|NEEDS-DECISION|NEEDS-INFO)$'

# Validate every line of every file. Prints one "groom-verdicts: refused: ..."
# line per violation (never stops early) so a subagent's whole file can be
# fixed in one pass, then returns the invalid-row count.
validate_files() {
    local file line lineno bad=0
    for file in "$@"; do
        [ -r "$file" ] || die "cannot read verdict file: $file"
        lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
            lineno=$((lineno + 1))
            [ -n "$line" ] || continue
            if ! jq -e . >/dev/null 2>&1 <<<"$line"; then
                echo "groom-verdicts: refused: $file:$lineno is not valid JSON" >&2
                bad=$((bad + 1))
                continue
            fi
            local number verdict priority reason evidence group question
            number="$(jq -r '.number // empty' <<<"$line")"
            verdict="$(jq -r '.verdict // empty' <<<"$line")"
            priority="$(jq -r '.priority // empty' <<<"$line")"
            reason="$(jq -r '.reason // empty' <<<"$line")"
            evidence="$(jq -r '.evidence // empty' <<<"$line")"
            group="$(jq -r '.group // empty' <<<"$line")"
            question="$(jq -r '.question // empty' <<<"$line")"

            if ! [[ "$number" =~ ^[0-9]+$ ]]; then
                echo "groom-verdicts: refused: $file:$lineno issue '$number' — number must be a positive integer" >&2
                bad=$((bad + 1))
                continue
            fi
            if ! [[ "$verdict" =~ $VERDICT_RE ]]; then
                echo "groom-verdicts: refused: #$number — unknown verdict '$verdict'" >&2
                bad=$((bad + 1))
                continue
            fi
            case "$priority" in
            high | medium | low) ;;
            *)
                echo "groom-verdicts: refused: #$number — priority must be high, medium, or low (got '$priority')" >&2
                bad=$((bad + 1))
                continue
                ;;
            esac
            if [ -z "$reason" ]; then
                echo "groom-verdicts: refused: #$number — reason is required" >&2
                bad=$((bad + 1))
                continue
            fi
            if [ -z "$group" ]; then
                echo "groom-verdicts: refused: #$number — group is required" >&2
                bad=$((bad + 1))
                continue
            fi
            if [[ "$verdict" =~ $CLOSE_RE ]] && [ -z "$evidence" ]; then
                echo "groom-verdicts: refused: #$number — a CLOSE verdict requires nonempty evidence" >&2
                bad=$((bad + 1))
                continue
            fi
            if [ "$verdict" = "NEEDS-DECISION" ] && [ -z "$question" ]; then
                echo "groom-verdicts: refused: #$number — NEEDS-DECISION requires a one-sentence question" >&2
                bad=$((bad + 1))
                continue
            fi
        done <"$file"
    done
    return "$bad"
}

cmd_validate() {
    [ "$#" -ge 1 ] || usage
    local bad=0
    validate_files "$@" || bad=$?
    [ "$bad" -eq 0 ] || exit 1
    echo "groom-verdicts: all rows verified"
}

cmd_join() {
    local repo="" scan="" out="" allow_missing=0 proposals=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --scan)
            [ "$#" -ge 2 ] || usage
            scan="$2"
            shift 2
            ;;
        --out)
            [ "$#" -ge 2 ] || usage
            out="$2"
            shift 2
            ;;
        --allow-missing)
            allow_missing=1
            shift
            ;;
        --proposals)
            [ "$#" -ge 2 ] || usage
            proposals="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*) usage ;;
        *) break ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$scan" ] && [ -n "$out" ] || usage
    [ -r "$scan" ] || die "cannot read scan dataset: $scan"

    local open_count
    open_count="$(jq '.open // [] | length' "$scan")"
    if [ "$#" -eq 0 ] && [ "$open_count" -ne 0 ]; then
        echo "groom-verdicts: refused: no verdict files given but scan.open has" \
            "$open_count open issue(s) — pass at least one cluster file" >&2
        exit 1
    fi

    local proposals_json="{}"
    if [ -n "$proposals" ]; then
        [ -r "$proposals" ] || die "cannot read proposals file: $proposals"
        jq -e . "$proposals" >/dev/null 2>&1 ||
            die "proposals file is not valid JSON: $proposals"
        proposals_json="$(cat "$proposals")"
    fi

    local bad=0
    if [ "$#" -ge 1 ]; then
        validate_files "$@" || bad=$?
        [ "$bad" -eq 0 ] || exit 1
    fi

    local rows_tmp
    rows_tmp="$(mktemp)" || die "could not create a temp file"
    trap 'rm -f "$rows_tmp"' RETURN
    for file in "$@"; do
        cat "$file" >>"$rows_tmp"
        printf '\n' >>"$rows_tmp"
    done

    # Coverage check (finding 3): every open issue must produce EXACTLY one
    # verdict row. A subagent that silently skips an issue, or two cluster
    # files that both cover the same one, must never ship an incomplete or
    # duplicated dataset with no signal that it happened.
    local coverage dup_list unknown_list missing_list missing_json
    coverage="$(jq -n --slurpfile scan "$scan" --slurpfile rows "$rows_tmp" '
      (($scan[0].open // []) | map(.number)) as $open_numbers
      | (($rows // []) | map(.number)) as $row_numbers
      | {
          duplicates: ($row_numbers | group_by(.) | map(select(length > 1) | .[0]) | unique),
          unknown: (($row_numbers - $open_numbers) | unique),
          missing: (($open_numbers - $row_numbers) | unique)
        }')"
    dup_list="$(jq -r '.duplicates[]' <<<"$coverage")"
    unknown_list="$(jq -r '.unknown[]' <<<"$coverage")"
    missing_list="$(jq -r '.missing[]' <<<"$coverage")"

    if [ -n "$dup_list" ]; then
        while IFS= read -r n; do
            echo "groom-verdicts: refused: #$n has more than one verdict row (duplicate)" >&2
        done <<<"$dup_list"
        exit 1
    fi
    if [ -n "$unknown_list" ]; then
        while IFS= read -r n; do
            echo "groom-verdicts: refused: #$n has a verdict row but is not in" \
                "scan.open (unknown issue number)" >&2
        done <<<"$unknown_list"
        exit 1
    fi
    if [ -n "$missing_list" ]; then
        if [ "$allow_missing" -ne 1 ]; then
            while IFS= read -r n; do
                echo "groom-verdicts: refused: #$n is open but has no verdict row" \
                    "(missing) — pass --allow-missing to proceed anyway" >&2
            done <<<"$missing_list"
            exit 1
        fi
        missing_json="$(jq -c '.missing' <<<"$coverage")"
    else
        missing_json="[]"
    fi

    jq -n --arg repo "$repo" \
        --slurpfile scan "$scan" \
        --slurpfile rows "$rows_tmp" \
        --argjson proposals "$proposals_json" \
        --argjson unverified "$missing_json" '
      ($scan[0]) as $scan
      | ($rows) as $dispositions0
      | ($scan.open | map({key: (.number|tostring), value: .}) | from_entries) as $by_number
      | [ $dispositions0[]
          | . as $row
          | ($by_number[($row.number|tostring)] // {}) as $issue
          | $row + {
              title: ($issue.title // null),
              bot_owned: ($issue.bot_owned // false),
              age_days: ($issue.age_days // null),
              days_since_update: ($issue.days_since_update // null),
              status: (.status // "PENDING")
            }
        ] as $dispositions
      | {
          repo: $repo,
          dispositions: $dispositions,
          stats: {
            open_total: ($scan.open_total // ($scan.open | length)),
            close_candidates:
              ([$dispositions[] | select(.verdict | startswith("CLOSE-"))] | length),
            decisions:
              ([$dispositions[] | select(.verdict == "NEEDS-DECISION")] | length),
            high_priority:
              ([$dispositions[] | select(.priority == "high")] | length),
            unverified: $unverified
          },
          milestones: ($scan.milestones // []),
          proposals: {
            parents: ($proposals.parents // []),
            milestones: ($proposals.milestones // [])
          }
        }' >"$out"
    echo "groom-verdicts: wrote $(jq '.dispositions | length' "$out") dispositions to $out"
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
validate) cmd_validate "$@" ;;
join) cmd_join "$@" ;;
*) usage ;;
esac
