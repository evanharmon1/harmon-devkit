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
# requires a nonempty `question` field (one sentence) and a nonempty
# `recommendation` field.
#
# Usage:
#   groom-verdicts.sh validate FILE...
#   groom-verdicts.sh join --repo owner/repo --scan PATH --out PATH
#                          [--allow-missing] [--proposals PATH]
#                          [--findings PATH] [--conformance PATH] FILE...
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
# collected parent/milestone regrouping proposals and themes:
#   {"parents":[{"parent":N|null,"title":"...","children":[N,...]}],
#    "milestones":[{"action":"close|rename|widen|create","title":"...",
#                    "new_title":"...","issues":[N,...],"reason":"..."}],
#    "themes":[{"title":"...","issues":[N,...],"reason":"...",
#              "recommended_vehicle":"openspec|bmad|adr"}],
#    "process_findings":[{"finding":"...","recommended_action":"..."}]}
# carried into the dataset for groom-report.sh to render.
#
# Every path argument (FILE..., --scan, --out, --proposals, --findings) is
# canonicalized and, when GROOM_SCRATCH is set, must lie under it — exactly
# like groom-scan.sh's guard_out_path — refused (exit 4) otherwise. Interactive
# use with GROOM_SCRATCH unset is unchanged.
#
# Exit: 0 = valid (validate) / dataset written (join), 1 = a row violates the
#       vocabulary contract, or coverage finds a duplicate/unknown/unallowed-
#       missing number, or a CLOSE-dup-of-# target is self-referential or not
#       in scan.open, or a proposals/findings payload is malformed (each names
#       the offending issue number(s) or payload), 2 = usage, or (join) the
#       scan's own repo field does not match --repo, 4 = refused (a path
#       argument outside GROOM_SCRATCH, when set, or GROOM_SCRATCH itself
#       does not exist).
set -euo pipefail

usage() {
    echo "Usage: $0 validate FILE..." >&2
    echo "       $0 join --repo owner/repo --scan PATH --out PATH" >&2
    echo "               [--allow-missing] [--proposals PATH] [--findings PATH] FILE..." >&2
    exit 2
}

die() {
    echo "groom-verdicts: $*" >&2
    exit 2
}

# Canonicalize PATH and refuse it (exit 4) unless it lies under this run's
# $GROOM_SCRATCH, same binding groom-scan.sh's guard_out_path enforces for
# --out (Codex review on PR #1032, comment 4011648576): a headless audit's
# worker treats issue text as untrusted, and unlike groom-scan.sh, neither
# this script nor groom-report.sh enforced GROOM_SCRATCH on the paths a
# model can pass, so a prompt-injected --out/--scan/verdict-file argument
# could escape the scoped Edit(//<run_dir>/**) grant. Interactive use with
# GROOM_SCRATCH unset is unchanged — every path is accepted as given.
guard_scratch_path() {
    local flag="$1" path="$2" dir base abs scratch
    [ -n "${GROOM_SCRATCH:-}" ] || return 0
    [ -n "$path" ] || return 0
    scratch="$(cd "$GROOM_SCRATCH" 2>/dev/null && pwd -P)" || {
        echo "groom-verdicts: refused: this run's scratch directory" \
            "($GROOM_SCRATCH) does not exist" >&2
        exit 4
    }
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    abs="$(cd "$dir" 2>/dev/null && pwd -P)/$base" || {
        echo "groom-verdicts: could not resolve $flag path: $path" >&2
        exit 2
    }
    case "$abs" in
    "$scratch"/*) ;;
    *)
        echo "groom-verdicts: refused: $flag must live under this run's" \
            "scratch directory ($GROOM_SCRATCH), got: $path" >&2
        exit 4
        ;;
    esac
}

# CLOSE-wrong-repo carries a real target description in its parens (e.g.
# "CLOSE-wrong-repo (harmonops/harmon-infra)"), per references/verdict-
# vocabulary.md and references/subagent-brief.md — a literal word "target"
# is the placeholder in the docs, not a value to match verbatim.
CLOSE_RE='^CLOSE-(done|obsolete|wrong-repo \([^)]+\)|dup-of-#[0-9]+)$'
VERDICT_RE='^(CLOSE-done|CLOSE-obsolete|CLOSE-wrong-repo \([^)]+\)|CLOSE-dup-of-#[0-9]+|KEEP|NEEDS-DECISION|NEEDS-INFO)$'
# The parenthetical after CLOSE-wrong-repo must be a real target description,
# not the literal word from the documented template
# (`CLOSE-wrong-repo (target)` in references/verdict-vocabulary.md and
# references/subagent-brief.md is a placeholder to fill in, not a value to
# copy verbatim — Codex review on PR #1032, comment 4011648585).
WRONG_REPO_RE='^CLOSE-wrong-repo \(([^)]+)\)$'

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
            local number verdict priority reason evidence group question recommendation
            number="$(jq -r '.number // empty' <<<"$line")"
            verdict="$(jq -r '.verdict // empty' <<<"$line")"
            priority="$(jq -r '.priority // empty' <<<"$line")"
            reason="$(jq -r '.reason // empty' <<<"$line")"
            evidence="$(jq -r '.evidence // empty' <<<"$line")"
            group="$(jq -r '.group // empty' <<<"$line")"
            question="$(jq -r '.question // empty' <<<"$line")"
            recommendation="$(jq -r '.recommendation // empty' <<<"$line")"

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
            if [[ "$verdict" =~ $WRONG_REPO_RE ]]; then
                local wrong_repo_target wrong_repo_compact
                wrong_repo_target="${BASH_REMATCH[1]}"
                wrong_repo_compact="$(printf '%s' "$wrong_repo_target" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
                # A whitespace-only parenthetical (e.g. "CLOSE-wrong-repo
                # (   )") satisfies WRONG_REPO_RE's [^)]+ and is not the
                # literal placeholder either, so it passed both checks below
                # with no destination repository named at all (Codex review
                # on PR #1032, comment 4012885435).
                if [ -z "$wrong_repo_compact" ]; then
                    echo "groom-verdicts: refused: #$number — CLOSE-wrong-repo needs a nonblank target description" >&2
                    bad=$((bad + 1))
                    continue
                fi
                if [ "$wrong_repo_compact" = "target" ]; then
                    echo "groom-verdicts: refused: #$number — CLOSE-wrong-repo needs a real target description, not the literal placeholder 'target'" >&2
                    bad=$((bad + 1))
                    continue
                fi
            fi
            case "$priority" in
            p0 | p1 | p2 | p3 | P0 | P1 | P2 | P3 | high | medium | low) ;;
            *)
                echo "groom-verdicts: refused: #$number — priority must be p0, p1, p2, p3, high, medium, or low (got '$priority')" >&2
                bad=$((bad + 1))
                continue
                ;;
            esac
            # `jq -r` coerces any JSON value (a number, `[]`, `null`) to a
            # shell string, so checking only `[ -z "$reason" ]` accepted a
            # non-string or whitespace-only reason even though the
            # documented schema requires a concrete nonempty string — the
            # same gap the evidence check below already closed (Codex review
            # on PR #1032, comment 4012242599).
            local reason_type reason_trimmed
            reason_type="$(jq -r '.reason | type' <<<"$line")"
            if [ "$reason_type" != "string" ]; then
                echo "groom-verdicts: refused: #$number — reason must be a JSON string (got $reason_type)" >&2
                bad=$((bad + 1))
                continue
            fi
            reason_trimmed="$(printf '%s' "$reason" | tr -d '[:space:]')"
            if [ -z "$reason_trimmed" ]; then
                echo "groom-verdicts: refused: #$number — reason is required" >&2
                bad=$((bad + 1))
                continue
            fi
            if [ -z "$group" ]; then
                echo "groom-verdicts: refused: #$number — group is required" >&2
                bad=$((bad + 1))
                continue
            fi
            if [[ "$verdict" =~ $CLOSE_RE ]]; then
                # `jq -r` coerces any JSON value (a number, `[]`, `null`) to a
                # shell string, so checking only `[ -z "$evidence" ]` accepted
                # a non-string or whitespace-only evidence field even though
                # the documented schema requires a concrete string (Codex
                # review on PR #1032, comment 4011648593).
                local evidence_type evidence_trimmed
                evidence_type="$(jq -r '.evidence | type' <<<"$line")"
                if [ "$evidence_type" != "string" ]; then
                    echo "groom-verdicts: refused: #$number — a CLOSE verdict requires evidence to be a JSON string (got $evidence_type)" >&2
                    bad=$((bad + 1))
                    continue
                fi
                evidence_trimmed="$(printf '%s' "$evidence" | tr -d '[:space:]')"
                if [ -z "$evidence_trimmed" ]; then
                    echo "groom-verdicts: refused: #$number — a CLOSE verdict requires nonempty evidence" >&2
                    bad=$((bad + 1))
                    continue
                fi
            fi
            if [ "$verdict" = "NEEDS-DECISION" ]; then
                # `jq -r` coerces an array or number to nonempty shell text
                # (e.g. `question: []` becomes the string "[]"), and a
                # whitespace-only string also passed the old `-z` check, so
                # malformed subagent output reached the maintainer as an
                # unusable decision prompt (Codex review on PR #1032, comment
                # 4012885444) — same JSON-type-then-trim check the evidence
                # and reason fields already require.
                local question_type question_trimmed
                question_type="$(jq -r '.question | type' <<<"$line")"
                if [ "$question_type" != "string" ]; then
                    echo "groom-verdicts: refused: #$number — NEEDS-DECISION requires question to be a JSON string (got $question_type)" >&2
                    bad=$((bad + 1))
                    continue
                fi
                question_trimmed="$(printf '%s' "$question" | tr -d '[:space:]')"
                if [ -z "$question_trimmed" ]; then
                    echo "groom-verdicts: refused: #$number — NEEDS-DECISION requires a one-sentence question" >&2
                    bad=$((bad + 1))
                    continue
                fi

                local recommendation_type recommendation_trimmed
                recommendation_type="$(jq -r '.recommendation | type' <<<"$line")"
                if [ "$recommendation_type" != "string" ]; then
                    echo "groom-verdicts: refused: #$number — NEEDS-DECISION requires recommendation to be a JSON string (got $recommendation_type)" >&2
                    bad=$((bad + 1))
                    continue
                fi
                recommendation_trimmed="$(printf '%s' "$recommendation" | tr -d '[:space:]')"
                if [ -z "$recommendation_trimmed" ]; then
                    echo "groom-verdicts: refused: #$number — NEEDS-DECISION requires a nonempty recommendation" >&2
                    bad=$((bad + 1))
                    continue
                fi
            fi
            if jq -e '.conformance != null and (.conformance | type != "array")' <<<"$line" >/dev/null 2>&1; then
                echo "groom-verdicts: refused: $file:$lineno issue '#$number' — conformance must be a JSON array" >&2
                bad=$((bad + 1))
                continue
            fi
        done <"$file"
    done
    # Cap the returned status at 1, never return the raw count (Codex review
    # on PR #1032, comment 4011648565): bash truncates an exit status to its
    # low 8 bits, so `return 256` (exactly 256 invalid rows) silently becomes
    # exit 0 and both callers below would treat validation as successful.
    [ "$bad" -eq 0 ] || return 1
    return 0
}

cmd_validate() {
    [ "$#" -ge 1 ] || usage
    local f
    for f in "$@"; do
        guard_scratch_path "verdict file" "$f"
    done
    local bad=0
    validate_files "$@" || bad=$?
    [ "$bad" -eq 0 ] || exit 1
    echo "groom-verdicts: all rows verified"
}

cmd_join() {
    local repo="" scan="" out="" allow_missing=0 proposals="" findings="" conformance="" pre_audit_triage=""
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
        --findings)
            [ "$#" -ge 2 ] || usage
            findings="$2"
            shift 2
            ;;
        --conformance)
            [ "$#" -ge 2 ] || usage
            conformance="$2"
            shift 2
            ;;
        --pre-audit-triage)
            [ "$#" -ge 2 ] || usage
            pre_audit_triage="$2"
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
    guard_scratch_path --scan "$scan"
    guard_scratch_path --out "$out"
    [ -z "$proposals" ] || guard_scratch_path --proposals "$proposals"
    [ -z "$findings" ] || guard_scratch_path --findings "$findings"
    [ -z "$conformance" ] || guard_scratch_path --conformance "$conformance"
    local f
    for f in "$@"; do
        guard_scratch_path "verdict file" "$f"
    done
    [ -r "$scan" ] || die "cannot read scan dataset: $scan"

    # Bind the joined dispositions to the SCANNED repository (Codex review on
    # PR #1032, comment 4012885488): without this, a scan collected for
    # repository A supplied to `join --repo B` never compared the two, and
    # A's issue rows were stamped as belonging to B — the report then leads
    # the maintainer to approve issue numbers under the wrong tracker
    # identity, and later apply commands target B. A scan with no `repo`
    # field (an older fixture, say) has nothing to compare and is accepted
    # unchanged.
    local scan_repo
    scan_repo="$(jq -r '.repo // empty' "$scan")" || die "cannot read scan dataset: $scan"
    if [ -n "$scan_repo" ] && [ "$scan_repo" != "$repo" ]; then
        die "refused: scan's repo '$scan_repo' does not match --repo '$repo'"
    fi

    local open_count
    open_count="$(jq '.open // [] | length' "$scan")"
    if [ "$#" -eq 0 ] && [ "$open_count" -ne 0 ]; then
        echo "groom-verdicts: refused: no verdict files given but scan.open has" \
            "$open_count open issue(s) — pass at least one cluster file" >&2
        exit 1
    fi

    local rows_tmp proposals_tmp="" findings_tmp="" pf_tmp="" conformance_tmp=""
    rows_tmp="$(mktemp)" || die "could not create a temp file"
    proposals_tmp="$(mktemp)" || die "could not create a temp file"
    findings_tmp="$(mktemp)" || die "could not create a temp file"
    pf_tmp="$(mktemp)" || die "could not create a temp file"
    conformance_tmp="$(mktemp)" || die "could not create a temp file"
    trap 'rm -f "$rows_tmp" "$proposals_tmp" "$findings_tmp" "$pf_tmp" "$conformance_tmp"' RETURN

    if [ -n "$proposals" ]; then
        [ -r "$proposals" ] || die "cannot read proposals file: $proposals"
        jq -e . "$proposals" >/dev/null 2>&1 ||
            die "proposals file is not valid JSON: $proposals"
        cp "$proposals" "$proposals_tmp"
    else
        echo "{}" >"$proposals_tmp"
    fi

    # Validate themes in proposals (Issue #1063):
    local themes_bad
    themes_bad="$(jq -r --slurpfile scan "$scan" --slurpfile p "$proposals_tmp" '
      ($scan[0].open // [] | map(.number)) as $open_numbers |
      ($p[0] // {}) as $prop |
      if ($prop | has("themes")) and $prop.themes != null then
        if ($prop.themes | type != "array") then
          "themes must be a JSON array"
        else
          ([ $prop.themes[] |
             if (type != "object") then "theme entry must be an object"
             elif (.title == null or (.title | type != "string") or ((.title | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "theme requires nonempty title"
             elif (.issues == null or (.issues | type != "array") or (.issues | length == 0) or ([.issues[] | . as $iss | select((type != "number") or (. <= 0) or ($open_numbers | index($iss) | not))] | length > 0)) then "theme requires issues array of positive integers from scanned backlog"
             elif (.reason == null or (.reason | type != "string") or ((.reason | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "theme requires nonempty reason"
             elif (.recommended_vehicle == null or (.recommended_vehicle | type != "string") or ((.recommended_vehicle | tostring) | ascii_downcase | IN("openspec", "bmad", "adr") | not)) then "theme recommended_vehicle must be openspec, bmad, or adr"
             else empty end
          ] | first // "")
        end
      else "" end
    ' <<<"{}")"
    if [ -n "$themes_bad" ]; then
        echo "groom-verdicts: refused: $themes_bad" >&2
        exit 1
    fi

    if [ -n "$findings" ]; then
        [ -r "$findings" ] || die "cannot read findings file: $findings"
        jq -e . "$findings" >/dev/null 2>&1 ||
            die "findings file is not valid JSON: $findings"
        cp "$findings" "$findings_tmp"
        local findings_type_bad
        findings_type_bad="$(jq -r --slurpfile f "$findings_tmp" 'if ($f[0] | type != "array") then "findings file must be a JSON array" else "" end' <<<"{}")"
        if [ -n "$findings_type_bad" ]; then
            echo "groom-verdicts: refused: $findings_type_bad" >&2
            exit 1
        fi
    else
        echo "[]" >"$findings_tmp"
    fi

    if [ -n "$conformance" ]; then
        [ -r "$conformance" ] || die "cannot read conformance file: $conformance"
        jq -e . "$conformance" >/dev/null 2>&1 ||
            die "conformance file is not valid JSON: $conformance"
        cp "$conformance" "$conformance_tmp"
        local conf_type_bad
        conf_type_bad="$(jq -r --slurpfile c "$conformance_tmp" 'if ($c[0] | type != "array") then "conformance file must be a JSON array" else "" end' <<<"{}")"
        if [ -n "$conf_type_bad" ]; then
            echo "groom-verdicts: refused: $conf_type_bad" >&2
            exit 1
        fi
    else
        echo "[]" >"$conformance_tmp"
    fi
    # Validate process_findings in proposals (Issue #1062):
    local prop_pf_bad
    prop_pf_bad="$(jq -r --slurpfile p "$proposals_tmp" '
      ($p[0] // {}) as $prop |
      if ($prop | has("process_findings")) and $prop.process_findings != null then
        if ($prop.process_findings | type != "array") then
          "process_findings must be a JSON array"
        else "" end
      else "" end
    ' <<<"{}")"
    if [ -n "$prop_pf_bad" ]; then
        echo "groom-verdicts: refused: $prop_pf_bad" >&2
        exit 1
    fi

    # Validate process_findings in proposals and/or findings file (Issue #1062):
    jq -c --slurpfile f "$findings_tmp" --slurpfile p "$proposals_tmp" '
      (((($p[0] // {}).process_findings // []) | if type == "array" then . else [] end) +
       (($f[0] // []) | if type == "array" then . else [] end))
    ' <<<"{}" >"$pf_tmp"

    local pf_bad
    pf_bad="$(jq -r --slurpfile pf "$pf_tmp" '
      ($pf[0] // []) as $items |
      if ($items | type != "array") then
        "process_findings must be a JSON array"
      else
        ([ $items[] |
           if (type != "object") then "process finding entry must be an object"
           elif (.finding == null or (.finding | type != "string") or ((.finding | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "process finding requires nonempty finding"
           elif (.recommended_action == null or (.recommended_action | type != "string") or ((.recommended_action | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "process finding requires nonempty recommended_action"
           else empty end
        ] | first // "")
      end
    ' <<<"{}")"
    if [ -n "$pf_bad" ]; then
        echo "groom-verdicts: refused: $pf_bad" >&2
        exit 1
    fi

    local bad=0
    if [ "$#" -ge 1 ]; then
        validate_files "$@" || bad=$?
        [ "$bad" -eq 0 ] || exit 1
    fi

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

    # CLOSE-dup-of-#N's target is a distinct open issue in the same
    # repository per references/verdict-vocabulary.md; the syntax check above
    # only validates the "#N" shape, and unknown/missing coverage above only
    # checks the row's OWN number, so a self-referential or nonexistent
    # target was accepted and presented as safe to close (Codex review on
    # PR #1032, comment 4011648588).
    local dup_target_bad
    dup_target_bad="$(jq -nc --slurpfile scan "$scan" --slurpfile rows "$rows_tmp" '
      (($scan[0].open // []) | map(.number)) as $open_numbers
      | ($rows // [])
      | map(select(.verdict | test("^CLOSE-dup-of-#[0-9]+$")))
      | map({number, target: (.verdict | capture("^CLOSE-dup-of-#(?<t>[0-9]+)$").t | tonumber)})
      | map(select(.target as $t | .number as $n | ($t == $n) or ($open_numbers | index($t) | not)))
    ')"
    if [ "$(jq 'length' <<<"$dup_target_bad")" -gt 0 ]; then
        while IFS= read -r bad_row; do
            local bad_number bad_target
            bad_number="$(jq -r '.number' <<<"$bad_row")"
            bad_target="$(jq -r '.target' <<<"$bad_row")"
            if [ "$bad_number" = "$bad_target" ]; then
                echo "groom-verdicts: refused: #$bad_number's CLOSE-dup-of-#$bad_target targets itself" >&2
            else
                echo "groom-verdicts: refused: #$bad_number's CLOSE-dup-of-#$bad_target targets an" \
                    "issue not in scan.open (nonexistent, closed, or otherwise unverifiable)" >&2
            fi
        done < <(jq -c '.[]' <<<"$dup_target_bad")
        exit 1
    fi

    # Validate conformance defects in --conformance and/or cluster verdict rows:
    local conf_bad
    conf_bad="$(jq -r --slurpfile scan "$scan" --slurpfile c "$conformance_tmp" --slurpfile rows "$rows_tmp" '
      (($scan[0].open // []) | map(.number)) as $open_numbers |
      (if ([$rows[] | select(.conformance != null and (.conformance | type != "array"))] | length > 0)
       then "conformance on verdict row must be a JSON array"
       else "" end) as $row_conf_err |
      if $row_conf_err != "" then $row_conf_err
      else
        ((($c[0] // []) | if type == "array" then . else [] end) +
         [ ($rows // [])[] | select(.conformance != null) | . as $r | (.conformance | if type == "array" then . else [] end)[] | . + {number: (.number // $r.number)} ]) as $items |
        ([ $items[] | . as $item |
           if ($item | type != "object") then "conformance defect entry must be an object"
           elif ($item.number == null or ($item.number | type != "number") or ($item.number <= 0) or ($open_numbers | index($item.number) | not)) then "conformance defect requires positive number from scanned backlog"
           elif ($item.kind == null or ($item.kind | type != "string") or (($item.kind | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "conformance defect requires nonempty kind"
           elif ($item.defect == null or ($item.defect | type != "string") or (($item.defect | tostring) | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "")) then "conformance defect requires nonempty defect"
           elif ($item.fix != null and (($item.fix | type != "string") or (($item.fix | tostring) | ascii_downcase | IN("a triage apply", "a retitle plan row", "a track-work tick", "a manual edit") | not))) then "conformance defect fix must be one of: a triage apply, a retitle plan row, a track-work tick, a manual edit"
           else empty end
        ] | first // "")
      end
    ' <<<"{}")"
    if [ -n "$conf_bad" ]; then
        echo "groom-verdicts: refused: $conf_bad" >&2
        exit 1
    fi

    jq -n --arg repo "$repo" \
        --arg pre_audit_triage "${pre_audit_triage:-}" \
        --slurpfile scan "$scan" \
        --slurpfile rows "$rows_tmp" \
        --slurpfile proposals "$proposals_tmp" \
        --slurpfile findings "$pf_tmp" \
        --slurpfile conf_in "$conformance_tmp" \
        --argjson unverified "$missing_json" '
      def normalize_conf_kind($k):
        ($k | tostring | ascii_downcase) as $l |
        if ($l | test("title")) then "Title"
        elif ($l | test("label")) then "Labels"
        elif ($l | test("body|criteria")) then "Body profile"
        elif ($l | test("claim|assignee")) then "Stale claims / assignees"
        else ($k | tostring) end;
      def normalize_conf_fix($f; $k):
        if ($f != null and ($f | tostring | length > 0)) then $f
        else
          (normalize_conf_kind($k)) as $nk |
          if $nk == "Title" then "a retitle plan row"
          elif $nk == "Labels" then "a triage apply"
          elif $nk == "Body profile" then "a track-work tick"
          elif $nk == "Stale claims / assignees" then "a manual edit"
          else "a manual edit" end
        end;
      ($scan[0]) as $scan
      | ($rows) as $dispositions0
      | ($proposals[0] // {}) as $proposals
      | ($findings[0] // []) as $findings
      | ($scan.open | map({key: (.number|tostring), value: .}) | from_entries) as $by_number
      | [ $dispositions0[]
          | . as $row
          | ($by_number[($row.number|tostring)] // {}) as $issue
          | $row + {
              title: ($issue.title // null),
              bot_owned: ($issue.bot_owned // false),
              age_days: ($issue.age_days // null),
              days_since_update: ($issue.days_since_update // null),
              status: (.status // "PENDING"),
              milestone: ($issue.milestone // null),
              blocking_count: (
                $issue.blocking_count //
                ($issue.blocking.totalCount // ($issue.blocking.nodes // [] | length) // ($issue.blocking // [] | length) // 0)
              ),
              blocked_by_count: (
                $issue.blocked_by_count //
                ($issue.blockedBy.totalCount // ($issue.blockedBy.nodes // [] | length) // ($issue.blockedBy // [] | length) // 0)
              )
            }
        ] as $dispositions
      | (((($conf_in[0] // []) | if type == "array" then . else [] end) +
          [ $dispositions0[] | select(.conformance != null) | . as $r | (.conformance | if type == "array" then . else [] end)[] | . + {number: (.number // $r.number)} ])
         | map({
             number: .number,
             title: ($by_number[(.number|tostring)].title // .title // ""),
             kind: normalize_conf_kind(.kind),
             defect: .defect,
             fix: normalize_conf_fix(.fix; .kind)
           })) as $subagent_defects
      | [ ($scan.open // [])[] | . as $iss | ($iss.conformance // {}) as $c |
          (if ($c.title_valid == false or (($c.flags // []) | index("title-malformed") != null)) then
             {number: $iss.number, title: $iss.title, kind: "Title", defect: "malformed issue title", fix: "a retitle plan row"}
           else empty end),
          (if (($c.flags // []) | index("title-long") != null) then
             {number: $iss.number, title: $iss.title, kind: "Title", defect: "title exceeds 100 characters", fix: "a retitle plan row"}
           else empty end),
          (if (($c.flags // []) | index("missing-work-type") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "missing work type", fix: "a triage apply"}
           else empty end),
          (if (($c.flags // []) | index("missing-needs-triage") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "missing needs-triage label", fix: "a triage apply"}
           else empty end),
          (if (($c.flags // []) | index("partially-classified") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "partially classified", fix: "a triage apply"}
           else empty end),
          (if (($c.flags // []) | index("needs-triage-removable") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "needs-triage label is removable", fix: "a triage apply"}
           else empty end),
          (if (($c.flags // []) | index("legacy-work-type-label") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "legacy work-type label", fix: "a triage apply"}
           else empty end),
          (if (($c.flags // []) | index("stale-claim-candidate") != null) then
             {number: $iss.number, title: $iss.title, kind: "Stale claims / assignees", defect: "stale claim candidate", fix: "a manual edit"}
           else empty end),
          (if (($c.flags // []) | index("blocked-candidate") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "blocked candidate", fix: "a manual edit"}
           else empty end),
          (if (($c.flags // []) | index("aging-needs-candidate") != null) then
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: "aging needs candidate", fix: "a manual edit"}
           else empty end),
          (if (($iss.body == null or (($iss.body | gsub("^[[:space:]]+|[[:space:]]+$"; "")) == "")) or (($c.flags // []) | index("empty-body") != null)) then
             {number: $iss.number, title: $iss.title, kind: "Body profile", defect: "empty body", fix: "a manual edit"}
           else empty end),
          (($c.flags // [])[] | select(startswith("axis-missing:")) |
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: ., fix: "a triage apply"}),
          (($c.flags // [])[] | select(startswith("axis-conflict:")) |
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: ., fix: "a triage apply"}),
          (($c.flags // [])[] | select(startswith("axis-unknown-value:")) |
             {number: $iss.number, title: $iss.title, kind: "Labels", defect: ., fix: "a triage apply"})
        ] as $scan_defects
      | ($subagent_defects + [ $scan_defects[] | . as $sd | select(($subagent_defects | any((.number == $sd.number) and (.defect == $sd.defect))) | not) ]) as $all_defects
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
              ([$dispositions[] | select((.priority // "") | test("(?i)^p[01]$|high"))] | length),
            unverified: $unverified,
            pre_audit_triage: (if $pre_audit_triage != "" then $pre_audit_triage else ($scan.pre_audit_triage // "not run") end)
          },
          conformance_defects: $all_defects,
          milestones: ($scan.milestones // []),
          process_findings: $findings,
          proposals: {
            parents: ($proposals.parents // []),
            milestones: ($proposals.milestones // []),
            themes: ($proposals.themes // []),
            process_findings: $findings
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
