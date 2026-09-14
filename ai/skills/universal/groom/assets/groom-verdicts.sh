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
#   groom-verdicts.sh join --repo owner/repo --scan PATH --out PATH FILE...
#
# `validate` only checks the vocabulary/evidence contract, printing every
# violation it finds (never stopping at the first) and exiting 1 if any row is
# invalid. `join` validates the same way, then merges every row with the
# matching open issue from the scan dataset (title, bot_owned, age) and
# computes the summary stats groom-report.sh renders.
#
# Exit: 0 = valid (validate) / dataset written (join), 1 = a row violates the
#       vocabulary contract (the issue number and reason are named), 2 = usage.
set -euo pipefail

usage() {
    echo "Usage: $0 validate FILE..." >&2
    echo "       $0 join --repo owner/repo --scan PATH --out PATH FILE..." >&2
    exit 2
}

die() {
    echo "groom-verdicts: $*" >&2
    exit 2
}

CLOSE_RE='^CLOSE-(done|obsolete|wrong-repo \(target\)|dup-of-#[0-9]+)$'
VERDICT_RE='^(CLOSE-done|CLOSE-obsolete|CLOSE-wrong-repo \(target\)|CLOSE-dup-of-#[0-9]+|KEEP|NEEDS-DECISION|NEEDS-INFO)$'

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
    local repo="" scan="" out=""
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
        --)
            shift
            break
            ;;
        -*) usage ;;
        *) break ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$scan" ] && [ -n "$out" ] && [ "$#" -ge 1 ] || usage
    [ -r "$scan" ] || die "cannot read scan dataset: $scan"

    local bad=0
    validate_files "$@" || bad=$?
    [ "$bad" -eq 0 ] || exit 1

    local rows_tmp
    rows_tmp="$(mktemp)" || die "could not create a temp file"
    trap 'rm -f "$rows_tmp"' RETURN
    for file in "$@"; do
        cat "$file" >>"$rows_tmp"
        printf '\n' >>"$rows_tmp"
    done

    jq -n --arg repo "$repo" \
        --slurpfile scan "$scan" \
        --slurpfile rows "$rows_tmp" '
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
              ([$dispositions[] | select(.priority == "high")] | length)
          },
          milestones: ($scan.milestones // [])
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
