#!/usr/bin/env bash
# groom-report.sh — render the groom dispositions dataset (groom-verdicts.sh
# join output) into a self-contained HTML report and a Markdown summary.
# Read-only: writes only to the two output files named on its command line,
# never to GitHub. Deterministic — the same dataset renders byte-identical
# output (the generation timestamp is injectable via GROOM_NOW for tests), so
# the HTML can be republished to the same Artifact after every apply step
# (issue #1015).
#
# Section order (fixed, per issues #1015, #1061, #1062, #1063):
# Stats strip; Visualizations (inline SVG charts in HTML); What to do next;
# Close now (table, every entry showing number AND title); Milestones;
# Parent issues; Spec-worthy themes; Decisions (ranked into top five, next
# ten, remainder by area with callouts and response lines); Completed this run;
# Process findings (two-column table); Bot-owned issues; Unverified (only when
# the dataset carries any — stats.unverified, from groom-verdicts.sh join
# --allow-missing); Every issue (full table with inline filter/search).
#
# Usage:
#   groom-report.sh render --dispositions PATH --out-html PATH --out-md PATH
#                           [--outcomes PATH]
#
# --outcomes PATH (optional) is a JSON Lines file of applied-write records
# written by groom-apply.sh/groom-decide.sh's own --outcomes flag:
#   {"issue":N,"op":"...","status":"DONE"|"DECIDED <date>","at":"<UTC>"}
# Outcomes are keyed by (issue, op), not by issue alone (Codex review on
# PR #1032, comment 4012885408): an issue can carry several approved
# operations (a retitle AND a close, say), or an apply run can fail partway
# through, and a status keyed by issue number only let ANY outcome for that
# issue overwrite the row's disposition regardless of which op it was for —
# a successful retitle followed by a failed close made a CLOSE-* row
# disappear from "Close now" and render as a completed close, even though the
# issue remained open. A row's `status` therefore comes only from the outcome
# of the op that matches its verdict — "close" for a CLOSE-* row, "decision"
# for a NEEDS-DECISION row — and every other recorded op (retitle, label,
# milestone-assign, sub-issue-link, blocked-by) never changes a row's status.
# The LAST record for a given (issue, op) pair overrides that row's `status`
# column — republishing the report after an apply step (SKILL.md Step 6)
# is otherwise a byte-identical re-render of the plan, forever showing
# PENDING no matter what was actually applied (finding 8).
# A --outcomes PATH that does not exist yet is an empty outcomes set (every
# row PENDING), noted on stderr rather than refused — the documented dry-run
# recipe (SKILL.md Step 6 item 3) points --outcomes at a file no apply step
# has written yet on its first render (challenge round 2 confirming round,
# finding 2). A PATH that exists but cannot be read is still an error.
#
# "Close now" and "Decisions" list only PENDING rows, and the Stats strip's
# close-candidate/decision counts and the "What to do next"/clean-backlog
# lines count PENDING rows only too: once outcomes are merged in, a DONE
# close or a DECIDED decision moves to the "Completed this run" section
# instead of continuing to render as still-actionable work on every
# successful post-apply re-render (Codex review on PR #1032, comment
# 4012242626). The clean-backlog line additionally requires
# stats.unverified to be empty — an incomplete audit (join --allow-missing)
# is never "clean", whatever the close/decision/finding counts say (Codex
# review on PR #1032, comment 4012242642).
#
# Every path argument (--dispositions, --outcomes, --out-html, --out-md) is
# canonicalized and, when GROOM_SCRATCH is set, must lie under it — exactly
# like groom-scan.sh's guard_out_path — refused (exit 4) otherwise.
# Interactive use with GROOM_SCRATCH unset is unchanged.
#
# Exit: 0 = rendered, 2 = usage/read error, 4 = refused (a path argument
#       outside GROOM_SCRATCH, when set, or GROOM_SCRATCH itself does not
#       exist).
set -euo pipefail

usage() {
    echo "Usage: $0 render --dispositions PATH --out-html PATH --out-md PATH" >&2
    echo "                 [--outcomes PATH]" >&2
    exit 2
}

die() {
    echo "groom-report: $*" >&2
    exit 2
}

# Canonicalize PATH and refuse it (exit 4) unless it lies under this run's
# $GROOM_SCRATCH, same binding groom-scan.sh's guard_out_path enforces for
# --out (Codex review on PR #1032, comment 4011648576): a headless audit's
# worker treats issue text as untrusted, and this script's --out-html/
# --out-md/--dispositions/--outcomes arguments were not bound to the run
# directory, so a prompt-injected argument (e.g. --out-md ./AGENTS.md) could
# escape the scoped Edit(//<run_dir>/**) grant and truncate an arbitrary
# worker-writable file. Interactive use with GROOM_SCRATCH unset is
# unchanged — every path is accepted as given.
guard_scratch_path() {
    local flag="$1" path="$2" dir base abs scratch
    [ -n "${GROOM_SCRATCH:-}" ] || return 0
    [ -n "$path" ] || return 0
    scratch="$(cd "$GROOM_SCRATCH" 2>/dev/null && pwd -P)" || {
        echo "groom-report: refused: this run's scratch directory" \
            "($GROOM_SCRATCH) does not exist" >&2
        exit 4
    }
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    abs="$(cd "$dir" 2>/dev/null && pwd -P)/$base" || {
        echo "groom-report: could not resolve $flag path: $path" >&2
        exit 2
    }
    case "$abs" in
    "$scratch"/*) ;;
    *)
        echo "groom-report: refused: $flag must live under this run's" \
            "scratch directory ($GROOM_SCRATCH), got: $path" >&2
        exit 4
        ;;
    esac
}

cmd_render() {
    local dispositions="" out_html="" out_md="" outcomes=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --dispositions)
            [ "$#" -ge 2 ] || usage
            dispositions="$2"
            shift 2
            ;;
        --out-html)
            [ "$#" -ge 2 ] || usage
            out_html="$2"
            shift 2
            ;;
        --out-md)
            [ "$#" -ge 2 ] || usage
            out_md="$2"
            shift 2
            ;;
        --outcomes)
            [ "$#" -ge 2 ] || usage
            outcomes="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    [ -n "$dispositions" ] && [ -n "$out_html" ] && [ -n "$out_md" ] || usage
    guard_scratch_path --dispositions "$dispositions"
    guard_scratch_path --out-html "$out_html"
    guard_scratch_path --out-md "$out_md"
    [ -z "$outcomes" ] || guard_scratch_path --outcomes "$outcomes"
    [ -r "$dispositions" ] || die "cannot read dispositions dataset: $dispositions"

    local now
    now="${GROOM_NOW:-$(date -u '+%Y-%m-%d %H:%M UTC')}"

    local outcomes_map="{}"
    if [ -n "$outcomes" ]; then
        if [ ! -e "$outcomes" ]; then
            echo "groom-report: no outcomes file yet at $outcomes — all rows PENDING" >&2
        else
            [ -r "$outcomes" ] || die "cannot read outcomes file: $outcomes"
            # Keyed by issue, THEN op (Codex review on PR #1032, comment
            # 4012885408) — see the header comment above. The last record
            # for a given (issue, op) pair wins, same last-write-wins
            # semantics as the old issue-only map.
            outcomes_map="$(jq -s '
              reduce .[] as $o ({}; .[($o.issue|tostring)][$o.op] = $o.status)
            ' "$outcomes")"
        fi
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # 1. Render Markdown Twin (--out-md)
    # ─────────────────────────────────────────────────────────────────────────
    jq -r --arg now "$now" --argjson outcomes_map "$outcomes_map" '
      def mdesc: if . == null then "" else
        (. | tostring | gsub("\r\n|\r|\n"; " ") | gsub("\\|"; "\\|")) end;
      def ititle(titles; n): "#" + (n|tostring) + " — " + (titles[(n|tostring)] // "(title unavailable)" | mdesc);
      def format_verdict(titles):
        if test("^CLOSE-dup-of-#[0-9]+$") then
          capture("^CLOSE-dup-of-#(?<t>[0-9]+)$").t as $t |
          "CLOSE-dup-of-#" + $t + " — " + (titles[$t] // "(title unavailable)" | mdesc)
        else
          (. | mdesc)
        end;
      def pscore:
        if ((.priority // "") | test("(?i)^p0$|urgent")) then 0
        elif ((.priority // "") | test("(?i)^p1$|high")) then 1
        elif ((.priority // "") | test("(?i)^p2$|medium")) then 2
        else 3 end;
      def pr_label:
        if pscore == 0 then "P0 (urgent)"
        elif pscore == 1 then "High (P1)"
        elif pscore == 2 then "Medium (P2)"
        else "Low (P3)" end;

      . as $d
      | ($d.dispositions // []
         | map(
             ($outcomes_map[(.number|tostring)] // {}) as $ops
             | . + {status: (
                 if (.verdict | startswith("CLOSE-")) then ($ops["close"] // .status // "PENDING")
                 elif (.verdict == "NEEDS-DECISION") then ($ops["decision"] // .status // "PENDING")
                 else (.status // "PENDING")
                 end
               )}
           )
        ) as $rows
      | ($rows | map({key: (.number|tostring), value: (.title // "(title unavailable)")}) | from_entries) as $titles

      | ([$rows[] | select(.verdict | startswith("CLOSE-"))]) as $close_all
      | ([$close_all[] | select(.status == "PENDING")]) as $close
      | ([$close_all[] | select(.status != "PENDING")]) as $close_done
      | ([$rows[] | select(.verdict == "NEEDS-DECISION")]) as $decisions_all
      | ([$decisions_all[] | select(.status == "PENDING")]) as $decisions
      | ([$decisions_all[] | select(.status != "PENDING")]) as $decisions_done
      | ([$rows[] | select(.bot_owned == true)]) as $bots
      | ($d.stats // {}) as $stats
      | ($d.milestones // []) as $milestones
      | ($d.process_findings // []) as $findings
      | ($d.proposals.parents // []) as $parents
      | ($d.proposals.milestones // []) as $milestone_proposals
      | ($d.proposals.themes // []) as $themes
      | ($stats.unverified // []) as $unverified

      # Ranking decisions: priority (P0 > P1 > P2 > P3), blocking count (descending), age (descending)
      | ($decisions | sort_by([ pscore, (- (.blocking_count // .blocked_by_count // 0)), (- (.age_days // 0)), .number ])) as $decisions_ranked
      | ($decisions_ranked[0:5]) as $top_five
      | ($decisions_ranked[5:15]) as $next_ten
      | ($decisions_ranked[15:]) as $remainder

      | "# Groom report — \($d.repo // "unknown")",
        "",
        "_Generated: \($now)_",
        "",
        "## Stats",
        "",
        "- Open issues: \($stats.open_total // 0)",
        "- Close candidates: \($close|length)",
        "- Decisions needed: \($decisions|length)",
        "- High priority: \($stats.high_priority // 0)",
        "",
        "## What to do next",
        "",
        (if ($close|length) > 0 then "1. Review \($close|length) close candidate(s) below." else empty end),
        (if ($decisions|length) > 0 then "1. Answer \($decisions|length) decision(s) below." else empty end),
        (if ($themes|length) > 0 then "1. Review \($themes|length) spec-worthy theme proposal(s) below." else empty end),
        (if ($findings|length) > 0 then "1. Review \($findings|length) process finding(s) below." else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($themes|length) == 0 and ($findings|length) == 0
            and ($unverified|length) == 0
         then "Nothing to do — backlog is clean this run." else empty end),
        "",
        "## Close now",
        "",
        (if ($close|length) == 0 then "None this run."
         else
           "| # | Title | Verdict | Priority | Group | Status | Reason / Evidence |",
           "| --- | --- | --- | --- | --- | --- | --- |",
           ($close[] | "| #\(.number) | \(.title // "(title unavailable)" | mdesc) | \(.verdict | format_verdict($titles)) | \(.priority | mdesc) | \(.group | mdesc) | \(.status // "PENDING" | mdesc) | \(.reason | mdesc)" + (if (.evidence // "") != "" then " — *Evidence:* " + (.evidence | mdesc) else "" end) + " |")
         end),
        "",
        "## Milestones",
        "",
        (if ($milestone_proposals|length) > 0 then
           ($milestone_proposals[] |
            . as $p |
            ([$milestones[] | select(.title == $p.title)] | first) as $m |
            ([$rows[] | select(.milestone == $p.title and .status != "DONE")] | sort_by(- (.age_days // 0)) | first) as $oldest |
            ([$rows[] | select(.milestone == $p.title and .status == "DONE" and (.verdict | startswith("CLOSE-")))] | length) as $closed_here |
            ((($m.open_issues // 0) - $closed_here) | if . < 0 then 0 else . end) as $m_open |
            (($m.closed_issues // 0) + $closed_here) as $m_closed |
            (if $m then
               "open: \($m_open), closed: \($m_closed)" + (if $oldest then ", oldest open issue: " + ititle($titles; $oldest.number) + " (\($oldest.age_days // 0) days old)" else ", no open issues" end)
             else
               "new milestone proposal"
             end) as $health |
            "- \($p.action | mdesc) \($p.title | mdesc)"
            + (if $p.new_title then " → \($p.new_title | mdesc)" else "" end)
            + " (health: \($health))"
            + (if (($p.issues // [])|length > 0)
               then " (" + (($p.issues // []) | map(ititle($titles; .)) | join(", ")) + ")"
               else "" end)
            + (if $p.reason then " — \($p.reason | mdesc)" else "" end))
         elif ($milestones|length) == 0 then "No milestone proposals this run."
         else
           ($milestones[] |
            . as $m |
            ([$rows[] | select(.milestone == $m.title and .status != "DONE")] | sort_by(- (.age_days // 0)) | first) as $oldest |
            ([$rows[] | select(.milestone == $m.title and .status == "DONE" and (.verdict | startswith("CLOSE-")))] | length) as $closed_here |
            ((($m.open_issues // 0) - $closed_here) | if . < 0 then 0 else . end) as $m_open |
            (($m.closed_issues // 0) + $closed_here) as $m_closed |
            "- #\($m.number) \($m.title | mdesc) (\($m.state | mdesc)) — \($m_open) open, \($m_closed) closed"
            + (if $oldest then " (health: open: \($m_open), closed: \($m_closed), oldest open issue: " + ititle($titles; $oldest.number) + " (\($oldest.age_days // 0) days old))" else " (health: open: \($m_open), closed: \($m_closed), no open issues)" end))
         end),
        "",
        "## Parent issues",
        "",
        (if ($parents|length) == 0 then "No parent-tree proposals this run."
         else ($parents[] |
               "- \(if .parent then ("#" + (.parent|tostring) + " — " + ((if (.title // "") != "" then .title else $titles[(.parent|tostring)] end) // "(title unavailable)" | mdesc)) else "(new) \(.title | mdesc)" end)"
               + (if (.children // [])|length > 0
                  then ": " + ((.children // []) | map(ititle($titles; .)) | join(", "))
                  else "" end))
         end),
        "",
        "## Spec-worthy themes",
        "",
        (if ($themes|length) == 0 then "No spec-worthy theme proposals this run."
         else ($themes[] |
               "### \(.title | mdesc)",
               "",
               "- Recommended vehicle: \(.recommended_vehicle | mdesc)",
               "- Reason: \(.reason | mdesc)",
               "- Candidate issues:",
               ((.issues // [])[] | "  - " + ititle($titles; .)),
               "- How to respond: Agree to draft spec via \(.recommended_vehicle | mdesc), or decline to keep as individual issues.",
               "")
         end),
        "",
        "## Decisions",
        "",
        (if ($decisions|length) == 0 then "None this run."
         else
           (if ($top_five|length) > 0 then
              "### Top five",
              "",
              ($top_five[] |
               . as $dec |
               (if pscore == 0 then "P0 (urgent)" elif pscore == 1 then "High (P1)" elif pscore == 2 then "Medium (P2)" else "Low (P3)" end) as $pr |
               "- " + ititle($titles; $dec.number) + " — \($dec.question // "" | mdesc)",
               "  - Recommendation: \($dec.recommendation // $dec.reason | mdesc)",
               "  - Why ranked in top five: \($pr) priority, blocks \($dec.blocking_count // $dec.blocked_by_count // 0) downstream issue(s), \($dec.age_days // 0) days old.",
               "  - How to respond: Reply \"agree\" to accept recommendation, \"decline\" to reject, or specify an alternative.",
               "  - Status: \($dec.status // "PENDING" | mdesc)",
               "")
            else empty end),
           (if ($next_ten|length) > 0 then
              "### Next ten",
              "",
              ($next_ten[] |
               . as $dec |
               "- " + ititle($titles; $dec.number) + " — \($dec.question // "" | mdesc)",
               "  - Recommendation: \($dec.recommendation // $dec.reason | mdesc)",
               "  - How to respond: Reply \"agree\" to accept recommendation, \"decline\" to reject, or specify an alternative.",
               "  - Status: \($dec.status // "PENDING" | mdesc)",
               "")
            else empty end),
           (if ($remainder|length) > 0 then
              "### Remainder by area",
              "",
              ($remainder | group_by(.group) | .[] |
               "#### \(.[0].group | mdesc)",
               "",
               (.[] |
                . as $dec |
                "- " + ititle($titles; $dec.number) + " — \($dec.question // "" | mdesc)",
                "  - Recommendation: \($dec.recommendation // $dec.reason | mdesc)",
                "  - How to respond: Reply \"agree\" to accept recommendation, \"decline\" to reject, or specify an alternative.",
                "  - Status: \($dec.status // "PENDING" | mdesc)",
                "")
              )
            else empty end)
         end),
        "",
        "## Completed this run",
        "",
        (if (($close_done|length) + ($decisions_done|length)) == 0 then "None this run."
         else (
           ($close_done[] | "- " + ititle($titles; .number) + " — close — status: \(.status | mdesc)"),
           ($decisions_done[] | "- " + ititle($titles; .number) + " — decision — status: \(.status | mdesc)")
         )
         end),
        "",
        "## Process findings",
        "",
        (if ($findings|length) == 0 then "None recorded this run."
         else
           "| Finding | Recommended action |",
           "| --- | --- |",
           ($findings[] | "| \(if type == "object" then (.finding // "" | mdesc) else (. | mdesc) end) | \(if type == "object" then (.recommended_action // "" | mdesc) else "Review finding" end) (How to respond: reply \"agree\" to apply remediation, or \"decline\") |")
         end),
        "",
        "## Bot-owned issues (excluded from retitle/close/relabel)",
        "",
        (if ($bots|length) == 0 then "None this run."
         else ($bots[] | "- " + ititle($titles; .number))
         end),
        "",
        (if ($unverified|length) == 0 then empty else
          "## Unverified",
          "",
          "Open issues with no verdict row this run (join --allow-missing):",
          "",
          ($unverified[] | "- " + ititle($titles; .)),
          ""
         end),
        "## Every issue",
        "",
        "| # | Title | Verdict | Priority | Group | Status |",
        "| --- | --- | --- | --- | --- | --- |",
        ($rows[] | "| #\(.number) | \(.title // "" | mdesc) | \(.verdict | mdesc) | \(.priority | mdesc) | \(.group | mdesc) | \(.status // "PENDING" | mdesc) |")
    ' "$dispositions" >"$out_md"

    # ─────────────────────────────────────────────────────────────────────────
    # 2. Render Self-Contained Styled HTML (--out-html)
    # ─────────────────────────────────────────────────────────────────────────
    jq -r --arg now "$now" --argjson outcomes_map "$outcomes_map" '
      def h: tostring
        | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
        | gsub("\""; "&quot;");
      def ititle_h(titles; n): "#" + (n|tostring) + " — " + (titles[(n|tostring)] // "(title unavailable)" | h);
      def format_verdict_h(titles):
        if test("^CLOSE-dup-of-#[0-9]+$") then
          capture("^CLOSE-dup-of-#(?<t>[0-9]+)$").t as $t |
          "CLOSE-dup-of-#" + $t + " — " + (titles[$t] // "(title unavailable)" | h)
        else
          (. | h)
        end;
      def pscore:
        if ((.priority // "") | test("(?i)^p0$|urgent")) then 0
        elif ((.priority // "") | test("(?i)^p1$|high")) then 1
        elif ((.priority // "") | test("(?i)^p2$|medium")) then 2
        else 3 end;
      def pr_label:
        if pscore == 0 then "P0 (urgent)"
        elif pscore == 1 then "High (P1)"
        elif pscore == 2 then "Medium (P2)"
        else "Low (P3)" end;

      . as $d
      | ($d.dispositions // []
         | map(
             ($outcomes_map[(.number|tostring)] // {}) as $ops
             | . + {status: (
                 if (.verdict | startswith("CLOSE-")) then ($ops["close"] // .status // "PENDING")
                 elif (.verdict == "NEEDS-DECISION") then ($ops["decision"] // .status // "PENDING")
                 else (.status // "PENDING")
                 end
               )}
           )
        ) as $rows
      | ($d.repo // "unknown") as $repo
      | ($rows | map({key: (.number|tostring), value: (.title // "(title unavailable)")}) | from_entries) as $titles

      | ([$rows[] | select(.verdict | startswith("CLOSE-"))]) as $close_all
      | ([$close_all[] | select(.status == "PENDING")]) as $close
      | ([$close_all[] | select(.status != "PENDING")]) as $close_done
      | ([$rows[] | select(.verdict == "NEEDS-DECISION")]) as $decisions_all
      | ([$decisions_all[] | select(.status == "PENDING")]) as $decisions
      | ([$decisions_all[] | select(.status != "PENDING")]) as $decisions_done
      | ([$rows[] | select(.bot_owned == true)]) as $bots
      | ($d.stats // {}) as $stats
      | ($d.milestones // []) as $milestones
      | ($d.process_findings // []) as $findings
      | ($d.proposals.parents // []) as $parents
      | ($d.proposals.milestones // []) as $milestone_proposals
      | ($d.proposals.themes // []) as $themes
      | ($stats.unverified // []) as $unverified

      # Ranking decisions: priority (P0 > P1 > P2 > P3), blocked-by count (descending), age (descending)
      | ($decisions | sort_by([ pscore, (- (.blocked_by_count // 0)), (- (.age_days // 0)), .number ])) as $decisions_ranked
      | ($decisions_ranked[0:5]) as $top_five
      | ($decisions_ranked[5:15]) as $next_ten
      | ($decisions_ranked[15:]) as $remainder

      # ── Inline SVG Chart 1: Verdict breakdown ──
      | [
          { label: "CLOSE-done", count: ([$rows[] | select(.verdict == "CLOSE-done")] | length), color: "#cf222e" },
          { label: "CLOSE-obsolete", count: ([$rows[] | select(.verdict == "CLOSE-obsolete")] | length), color: "#bc4c00" },
          { label: "CLOSE-dup", count: ([$rows[] | select(.verdict | startswith("CLOSE-dup"))] | length), color: "#8250df" },
          { label: "CLOSE-wrong-repo", count: ([$rows[] | select(.verdict | startswith("CLOSE-wrong-repo"))] | length), color: "#bf8700" },
          { label: "KEEP", count: ([$rows[] | select(.verdict == "KEEP")] | length), color: "#2da44e" },
          { label: "NEEDS-DECISION", count: ([$rows[] | select(.verdict == "NEEDS-DECISION")] | length), color: "#0969da" },
          { label: "NEEDS-INFO", count: ([$rows[] | select(.verdict == "NEEDS-INFO")] | length), color: "#656d76" }
        ] as $v_data
      | (([$v_data[].count] | max) // 1) as $v_max0
      | (if $v_max0 == 0 then 1 else $v_max0 end) as $v_max

      # ── Inline SVG Chart 2: Priority mix ──
      | [
          { label: "High", count: ([$rows[] | select(.priority == "high")] | length), color: "#cf222e" },
          { label: "Medium", count: ([$rows[] | select(.priority == "medium")] | length), color: "#d4a72c" },
          { label: "Low", count: ([$rows[] | select(.priority == "low")] | length), color: "#0969da" }
        ] as $p_data
      | (([$p_data[].count] | max) // 1) as $p_max0
      | (if $p_max0 == 0 then 1 else $p_max0 end) as $p_max

      # ── Inline SVG Chart 3: Backlog age distribution ──
      | [
          { label: "< 30d", count: ([$rows[] | select((.age_days // 0) < 30)] | length), color: "#2da44e" },
          { label: "30–90d", count: ([$rows[] | select((.age_days // 0) >= 30 and (.age_days // 0) <= 90)] | length), color: "#0969da" },
          { label: "90–180d", count: ([$rows[] | select((.age_days // 0) > 90 and (.age_days // 0) <= 180)] | length), color: "#d4a72c" },
          { label: "180–365d", count: ([$rows[] | select((.age_days // 0) > 180 and (.age_days // 0) <= 365)] | length), color: "#bc4c00" },
          { label: "> 365d", count: ([$rows[] | select((.age_days // 0) > 365)] | length), color: "#cf222e" }
        ] as $a_data
      | (([$a_data[].count] | max) // 1) as $a_max0
      | (if $a_max0 == 0 then 1 else $a_max0 end) as $a_max

      # ── Inline SVG Chart 4: Closes by evidence type ──
      | [
          { label: "Merged PR", count: ([$close_all[] | select((.evidence // "") | test("(?i)\\b(pull request|pull|pr)\\b|#[0-9]+|\\bmerged\\b"))] | length), color: "#2da44e" },
          { label: "Commit / SHA", count: ([$close_all[] | select(((.evidence // "") | test("(?i)pr|pull|merged") | not) and ((.evidence // "") | test("(?i)commit|sha|[0-9a-f]{7,40}")))] | length), color: "#0969da" },
          { label: "File:line", count: ([$close_all[] | select(((.evidence // "") | test("(?i)pr|pull|merged|commit|sha|[0-9a-f]{7,40}") | not) and ((.evidence // "") | test("(?i):[0-9]+|/|\\.[a-z]+:")))] | length), color: "#8250df" },
          { label: "Duplicate link", count: ([$close_all[] | select(((.evidence // "") | test("(?i)pr|pull|merged|commit|sha|[0-9a-f]{7,40}|:[0-9]+|/|\\.[a-z]+:") | not) and ((.evidence // "") | test("(?i)dup|#[0-9]+")))] | length), color: "#d4a72c" },
          { label: "Other / target", count: ([$close_all[] | select((.evidence // "") | test("(?i)pr|pull|merged|commit|sha|[0-9a-f]{7,40}|:[0-9]+|/|\\.[a-z]+:|dup|#[0-9]+") | not)] | length), color: "#656d76" }
        ] as $e_data
      | (([$e_data[].count] | max) // 1) as $e_max0
      | (if $e_max0 == 0 then 1 else $e_max0 end) as $e_max

      | "<!doctype html><meta charset=\"utf-8\">",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
        "<title>Groom report — \($repo|h)</title>",
        "<style>",
        ":root {",
        "  --bg: #ffffff;",
        "  --text: #1f2328;",
        "  --muted: #656d76;",
        "  --border: #d0d7de;",
        "  --th-bg: #f6f8fa;",
        "  --callout-bg: #ddf4ff;",
        "  --callout-border: #0969da;",
        "  --card-bg: #f6f8fa;",
        "  --nav-bg: #f6f8fa;",
        "  --link: #0969da;",
        "  --badge-bg: #eaeef2;",
        "  --badge-text: #24292f;",
        "}",
        "@media (prefers-color-scheme: dark) {",
        "  :root {",
        "    --bg: #0d1117;",
        "    --text: #e6edf3;",
        "    --muted: #848d97;",
        "    --border: #30363d;",
        "    --th-bg: #161b22;",
        "    --callout-bg: #0c2d6b;",
        "    --callout-border: #388bfd;",
        "    --card-bg: #161b22;",
        "    --nav-bg: #161b22;",
        "    --link: #58a6ff;",
        "    --badge-bg: #21262d;",
        "    --badge-text: #c9d1d9;",
        "  }",
        "}",
        "body { font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif; margin: 0; padding: 2rem; color: var(--text); background: var(--bg); line-height: 1.5; }",
        "h1 { font-size: 1.6rem; margin: 0 0 0.5rem; }",
        "h2 { font-size: 1.25rem; margin-top: 2rem; margin-bottom: 0.75rem; border-bottom: 1px solid var(--border); padding-bottom: 0.35rem; }",
        "h3 { font-size: 1.05rem; margin-top: 1.25rem; margin-bottom: 0.5rem; }",
        "h4 { font-size: 0.95rem; margin-top: 1rem; margin-bottom: 0.25rem; }",
        "nav.nav { position: sticky; top: 0; background: var(--nav-bg); border-bottom: 1px solid var(--border); padding: 0.6rem 1rem; margin: -2rem -2rem 1.5rem -2rem; z-index: 100; display: flex; flex-wrap: wrap; gap: 0.85rem; font-size: 0.85rem; }",
        "nav.nav a { color: var(--link); text-decoration: none; font-weight: 500; }",
        "nav.nav a:hover { text-decoration: underline; }",
        ".stats-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 1rem; margin: 1rem 0; }",
        ".stat-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 6px; padding: 0.85rem 1rem; }",
        ".stat-num { font-size: 1.5rem; font-weight: 700; color: var(--link); }",
        ".stat-label { font-size: 0.85rem; color: var(--muted); }",
        ".charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.25rem; margin: 1rem 0; }",
        ".chart-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; }",
        "table { border-collapse: collapse; width: 100%; margin: 0.75rem 0; font-size: 0.88rem; }",
        "th, td { border: 1px solid var(--border); padding: 0.45rem 0.65rem; text-align: left; }",
        "th { background: var(--th-bg); position: sticky; top: 2.2rem; }",
        "th.sortable { cursor: pointer; user-select: none; }",
        "th.sortable:hover { text-decoration: underline; }",
        "input[type=search] { padding: 0.4rem 0.6rem; width: 100%; max-width: 26rem; margin: 0.5rem 0; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--text); }",
        ".callout { background: var(--callout-bg); border-left: 4px solid var(--callout-border); padding: 0.75rem 1rem; margin: 0.5rem 0; border-radius: 0 4px 4px 0; }",
        ".callout-title { font-weight: 600; margin-bottom: 0.25rem; }",
        ".callout-body { margin: 0.25rem 0; }",
        ".callout-response { font-size: 0.85rem; color: var(--muted); margin: 0.5rem 0 0 0; font-style: italic; }",
        ".badge { display: inline-block; padding: 0.15rem 0.45rem; font-size: 0.75rem; font-weight: 600; border-radius: 12px; background: var(--badge-bg); color: var(--badge-text); }",
        ".badge-priority-high { background: #ffebe9; color: #cf222e; }",
        ".badge-priority-medium { background: #fff8c5; color: #9a6700; }",
        ".badge-priority-low { background: #ddf4ff; color: #0969da; }",
        "@media (prefers-color-scheme: dark) {",
        "  .badge-priority-high { background: #490202; color: #ff8182; }",
        "  .badge-priority-medium { background: #3d2a00; color: #d29922; }",
        "  .badge-priority-low { background: #0c2d6b; color: #58a6ff; }",
        "}",
        ".card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; margin: 0.75rem 0; }",
        "svg text { font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif; font-size: 11px; fill: currentColor; }",
        "</style>",
        "<nav class=\"nav\">",
        "<a href=\"#stats\">Stats</a>",
        "<a href=\"#visualizations\">Visualizations</a>",
        "<a href=\"#next\">What to do next</a>",
        "<a href=\"#close\">Close now</a>",
        "<a href=\"#milestones\">Milestones</a>",
        "<a href=\"#parents\">Parent issues</a>",
        "<a href=\"#themes\">Spec-worthy themes</a>",
        "<a href=\"#decisions\">Decisions</a>",
        "<a href=\"#completed\">Completed this run</a>",
        "<a href=\"#findings\">Process findings</a>",
        "<a href=\"#bots\">Bot-owned</a>",
        "<a href=\"#every-issue\">Every issue</a>",
        "</nav>",
        "<h1>Groom report — \($repo|h)</h1>",
        "<p><em>Generated: \($now|h)</em></p>",
        "<h2 id=\"stats\">Stats</h2>",
        "<div class=\"stats-strip\">",
        "<div class=\"stat-card\"><div class=\"stat-num\">\($stats.open_total // 0)</div><div class=\"stat-label\">Open issues</div></div>",
        "<div class=\"stat-card\"><div class=\"stat-num\">\($close|length)</div><div class=\"stat-label\">Close candidates</div></div>",
        "<div class=\"stat-card\"><div class=\"stat-num\">\($decisions|length)</div><div class=\"stat-label\">Decisions needed</div></div>",
        "<div class=\"stat-card\"><div class=\"stat-num\">\($stats.high_priority // 0)</div><div class=\"stat-label\">High priority</div></div>",
        "</div>",
        "<h2 id=\"visualizations\">Visualizations</h2>",
        "<div class=\"charts-grid\">",
        # Chart 1: Verdict breakdown
        "<div class=\"chart-card\" id=\"chart-verdicts\">",
        "<h3>Verdict breakdown</h3>",
        "<svg viewBox=\"0 0 380 180\" width=\"100%\" height=\"180\" role=\"img\" aria-label=\"Verdict breakdown\">",
        "<title>Verdict breakdown</title>",
        ([range(0; $v_data|length) | . as $i | ($v_data[$i]) as $item | (12 + $i * 24) as $y | (if $item.count > 0 then ($item.count * 170 / $v_max | floor) else 0 end) as $bw |
          "<text x=\"10\" y=\"\($y + 11)\">\($item.label|h)</text>"
          + "<rect x=\"145\" y=\"\($y)\" width=\"\($bw)\" height=\"14\" rx=\"3\" fill=\"\($item.color)\" />"
          + "<text x=\"\(152 + $bw)\" y=\"\($y + 11)\">\($item.count)</text>"
         ] | join("")),
        "</svg>",
        "</div>",
        # Chart 2: Priority mix
        "<div class=\"chart-card\" id=\"chart-priority\">",
        "<h3>Priority mix</h3>",
        "<svg viewBox=\"0 0 380 100\" width=\"100%\" height=\"100\" role=\"img\" aria-label=\"Priority mix\">",
        "<title>Priority mix</title>",
        ([range(0; $p_data|length) | . as $i | ($p_data[$i]) as $item | (16 + $i * 26) as $y | (if $item.count > 0 then ($item.count * 170 / $p_max | floor) else 0 end) as $bw |
          "<text x=\"10\" y=\"\($y + 12)\">\($item.label|h)</text>"
          + "<rect x=\"100\" y=\"\($y)\" width=\"\($bw)\" height=\"16\" rx=\"3\" fill=\"\($item.color)\" />"
          + "<text x=\"\(108 + $bw)\" y=\"\($y + 12)\">\($item.count)</text>"
         ] | join("")),
        "</svg>",
        "</div>",
        # Chart 3: Backlog age distribution
        "<div class=\"chart-card\" id=\"chart-age\">",
        "<h3>Backlog age distribution</h3>",
        "<svg viewBox=\"0 0 380 145\" width=\"100%\" height=\"145\" role=\"img\" aria-label=\"Backlog age distribution\">",
        "<title>Backlog age distribution</title>",
        ([range(0; $a_data|length) | . as $i | ($a_data[$i]) as $item | (12 + $i * 25) as $y | (if $item.count > 0 then ($item.count * 170 / $a_max | floor) else 0 end) as $bw |
          "<text x=\"10\" y=\"\($y + 12)\">\($item.label|h)</text>"
          + "<rect x=\"100\" y=\"\($y)\" width=\"\($bw)\" height=\"15\" rx=\"3\" fill=\"\($item.color)\" />"
          + "<text x=\"\(108 + $bw)\" y=\"\($y + 12)\">\($item.count)</text>"
         ] | join("")),
        "</svg>",
        "</div>",
        # Chart 4: Closes by evidence type
        "<div class=\"chart-card\" id=\"chart-evidence\">",
        "<h3>Closes by evidence type</h3>",
        "<svg viewBox=\"0 0 380 145\" width=\"100%\" height=\"145\" role=\"img\" aria-label=\"Closes by evidence type\">",
        "<title>Closes by evidence type</title>",
        ([range(0; $e_data|length) | . as $i | ($e_data[$i]) as $item | (12 + $i * 25) as $y | (if $item.count > 0 then ($item.count * 170 / $e_max | floor) else 0 end) as $bw |
          "<text x=\"10\" y=\"\($y + 12)\">\($item.label|h)</text>"
          + "<rect x=\"130\" y=\"\($y)\" width=\"\($bw)\" height=\"15\" rx=\"3\" fill=\"\($item.color)\" />"
          + "<text x=\"\(138 + $bw)\" y=\"\($y + 12)\">\($item.count)</text>"
         ] | join("")),
        "</svg>",
        "</div>",
        "</div>",
        "<h2 id=\"next\">What to do next</h2>",
        "<ol>",
        (if ($close|length) > 0 then "<li>Review \($close|length) close candidate(s) below.</li>" else empty end),
        (if ($decisions|length) > 0 then "<li>Answer \($decisions|length) decision(s) below.</li>" else empty end),
        (if ($themes|length) > 0 then "<li>Review \($themes|length) spec-worthy theme proposal(s) below.</li>" else empty end),
        (if ($findings|length) > 0 then "<li>Review \($findings|length) process finding(s) below.</li>" else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($themes|length) == 0 and ($findings|length) == 0
            and ($unverified|length) == 0
         then "<li>Nothing to do — backlog is clean this run.</li>" else empty end),
        "</ol>",
        "<h2 id=\"close\">Close now</h2>",
        (if ($close|length) == 0 then "<p>None this run.</p>"
         else
           "<input type=\"search\" id=\"q-close\" placeholder=\"Filter close candidates…\" onkeyup=\"groomFilterTable('q-close', 'table-close')\">"
           + "<table id=\"table-close\"><thead><tr>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 0)\">#</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 1)\">Title</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 2)\">Verdict</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 3)\">Priority</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 4)\">Group</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 5)\">Status</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable('table-close', 6)\">Reason / Evidence</th>"
           + "</tr></thead><tbody>"
           + ([$close[] | "<tr><td>#\(.number)</td><td>\(.title // "(title unavailable)"|h)</td><td><span class=\"badge\">\(.verdict | format_verdict_h($titles))</span></td><td><span class=\"badge badge-priority-\(.priority|h)\">\(.priority|h)</span></td><td>\(.group|h)</td><td>\(.status // "PENDING"|h)</td><td>\(.reason|h)" + (if (.evidence // "") != "" then "<br><small><strong>Evidence:</strong> \(.evidence|h)</small>" else "" end) + "</td></tr>"] | join(""))
           + "</tbody></table>"
         end),
        "<h2 id=\"milestones\">Milestones</h2>",
        (if ($milestone_proposals|length) > 0 then
           "<ul>" + ([$milestone_proposals[] |
             . as $p |
             ([$milestones[] | select(.title == $p.title)] | first) as $m |
             ([$rows[] | select(.milestone == $p.title and .status != "DONE")] | sort_by(- (.age_days // 0)) | first) as $oldest |
             ([$rows[] | select(.milestone == $p.title and .status == "DONE" and (.verdict | startswith("CLOSE-")))] | length) as $closed_here |
             ((($m.open_issues // 0) - $closed_here) | if . < 0 then 0 else . end) as $m_open |
             (($m.closed_issues // 0) + $closed_here) as $m_closed |
             (if $m then
                "open: \($m_open), closed: \($m_closed)" + (if $oldest then ", oldest open issue: " + ititle_h($titles; $oldest.number) + " (\($oldest.age_days // 0) days old)" else ", no open issues" end)
              else
                "new milestone proposal"
              end) as $health |
             "<li><strong>\($p.action|h) \($p.title|h)"
             + (if $p.new_title then " → \($p.new_title|h)" else "" end) + "</strong>"
             + " <span class=\"badge\">health: \($health)</span>"
             + (if (($p.issues // [])|length > 0)
                then " (" + (($p.issues // []) | map(ititle_h($titles; .)) | join(", ")) + ")"
                else "" end)
             + (if $p.reason then " — \($p.reason|h)" else "" end)
             + "</li>"] | join("")) + "</ul>"
         elif ($milestones|length) == 0 then "<p>No milestone proposals this run.</p>"
         else
           "<ul>" + ([$milestones[] |
             . as $m |
             ([$rows[] | select(.milestone == $m.title and .status != "DONE")] | sort_by(- (.age_days // 0)) | first) as $oldest |
             ([$rows[] | select(.milestone == $m.title and .status == "DONE" and (.verdict | startswith("CLOSE-")))] | length) as $closed_here |
             ((($m.open_issues // 0) - $closed_here) | if . < 0 then 0 else . end) as $m_open |
             (($m.closed_issues // 0) + $closed_here) as $m_closed |
             "<li>#\($m.number) \($m.title|h) (\($m.state|h)) — \($m_open) open, \($m_closed) closed"
             + (if $oldest then " (health: open: \($m_open), closed: \($m_closed), oldest open issue: " + ititle_h($titles; $oldest.number) + " (\($oldest.age_days // 0) days old))" else " (health: open: \($m_open), closed: \($m_closed), no open issues)" end)
             + "</li>"] | join("")) + "</ul>"
         end),
        "<h2 id=\"parents\">Parent issues</h2>",
        (if ($parents|length) == 0 then "<p>No parent-tree proposals this run.</p>"
         else "<ul>" + ([$parents[] |
             "<li>\(if .parent then ("#" + (.parent|tostring) + " — " + ((if (.title // "") != "" then .title else $titles[(.parent|tostring)] end) // "(title unavailable)" | h)) else "(new) \(.title|h)" end)"
             + (if (.children // [])|length > 0
                then ": " + ((.children // []) | map(ititle_h($titles; .)) | join(", "))
                else "" end)
             + "</li>"] | join("")) + "</ul>"
         end),
        "<h2 id=\"themes\">Spec-worthy themes</h2>",
        (if ($themes|length) == 0 then "<p>No spec-worthy theme proposals this run.</p>"
         else ([$themes[] |
           "<div class=\"card theme-card\">"
           + "<h3>\(.title|h) <span class=\"badge\">\(.recommended_vehicle|h)</span></h3>"
           + "<p><strong>Reason:</strong> \(.reason|h)</p>"
           + "<p><strong>Candidate issues:</strong></p><ul>"
           + ([(.issues // [])[] | "<li>" + ititle_h($titles; .) + "</li>"] | join(""))
           + "</ul>"
           + "<div class=\"callout callout-theme\"><p class=\"callout-response\"><strong>How to respond:</strong> Agree to draft spec via \(.recommended_vehicle|h), or decline to keep as individual issues.</p></div>"
           + "</div>"
         ] | join(""))
         end),
        "<h2 id=\"decisions\">Decisions</h2>",
        (if ($decisions|length) == 0 then "<p>None this run.</p>"
         else
           (if ($top_five|length) > 0 then
              "<h3>Top five</h3><ul>"
              + ([$top_five[] |
                 . as $dec |
                 (if pscore == 0 then "P0 (urgent)" elif pscore == 1 then "High (P1)" elif pscore == 2 then "Medium (P2)" else "Low (P3)" end) as $pr |
                 "<li><strong>" + ititle_h($titles; $dec.number) + "</strong> — \($dec.question // ""|h)"
                 + "<div class=\"callout callout-decision\">"
                 + "<div class=\"callout-title\">Recommendation</div>"
                 + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                 + "<p class=\"callout-body\"><small><strong>Why ranked in top five:</strong> \($pr) priority, blocks \($dec.blocking_count // $dec.blocked_by_count // 0) downstream issue(s), \($dec.age_days // 0) days old.</small></p>"
                 + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                 + "</div>"
                 + "<p><small>Status: \($dec.status // "PENDING"|h)</small></p>"
                 + "</li>"] | join(""))
              + "</ul>"
            else "" end)
           + (if ($next_ten|length) > 0 then
              "<h3>Next ten</h3><ul>"
              + ([$next_ten[] |
                 . as $dec |
                 "<li><strong>" + ititle_h($titles; $dec.number) + "</strong> — \($dec.question // ""|h)"
                 + "<div class=\"callout callout-decision\">"
                 + "<div class=\"callout-title\">Recommendation</div>"
                 + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                 + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                 + "</div>"
                 + "<p><small>Status: \($dec.status // "PENDING"|h)</small></p>"
                 + "</li>"] | join(""))
              + "</ul>"
            else "" end)
           + (if ($remainder|length) > 0 then
              "<h3>Remainder by area</h3>"
              + ([$remainder | group_by(.group) | .[] |
                 "<h4>\(.[0].group|h)</h4><ul>"
                 + ([.[] |
                    . as $dec |
                    "<li><strong>" + ititle_h($titles; $dec.number) + "</strong> — \($dec.question // ""|h)"
                    + "<div class=\"callout callout-decision\">"
                    + "<div class=\"callout-title\">Recommendation</div>"
                    + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                    + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                    + "</div>"
                    + "<p><small>Status: \($dec.status // "PENDING"|h)</small></p>"
                    + "</li>"] | join(""))
                 + "</ul>"] | join(""))
            else "" end)
         end),
        "<h2 id=\"completed\">Completed this run</h2>",
        (if (($close_done|length) + ($decisions_done|length)) == 0 then "<p>None this run.</p>"
         else "<ul>"
           + ([$close_done[] | "<li>" + ititle_h($titles; .number) + " — close — status: \(.status|h)</li>"] | join(""))
           + ([$decisions_done[] | "<li>" + ititle_h($titles; .number) + " — decision — status: \(.status|h)</li>"] | join(""))
           + "</ul>"
         end),
        "<h2 id=\"findings\">Process findings</h2>",
        (if ($findings|length) == 0 then "<p>None recorded this run.</p>"
         else
           "<table><thead><tr><th>Finding</th><th>Recommended action</th></tr></thead><tbody>"
           + ([$findings[] |
              (if type == "object" then .finding else . end) as $f_text |
              (if type == "object" then .recommended_action else "Review finding" end) as $f_act |
              "<tr><td>\($f_text|h)</td><td>"
              + "<div class=\"callout callout-finding\">"
              + "<p class=\"callout-body\">\($f_act|h)</p>"
              + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to apply remediation, or &quot;decline&quot;.</p>"
              + "</div>"
              + "</td></tr>"] | join(""))
           + "</tbody></table>"
         end),
        "<h2 id=\"bots\">Bot-owned issues (excluded from retitle/close/relabel)</h2>",
        (if ($bots|length) == 0 then "<p>None this run.</p>"
         else "<ul>" + ([$bots[] | "<li>" + ititle_h($titles; .number) + "</li>"] | join("")) + "</ul>"
         end),
        (if ($unverified|length) == 0 then empty else
          "<h2 id=\"unverified\">Unverified</h2>",
          "<p>Open issues with no verdict row this run (join --allow-missing):</p>",
          "<ul>" + ([$unverified[] | "<li>" + ititle_h($titles; .) + "</li>"] | join("")) + "</ul>"
         end),
        "<h2 id=\"every-issue\">Every issue</h2>",
        "<input type=\"search\" id=\"q\" placeholder=\"Filter by number, title, verdict, group…\" onkeyup=\"groomFilter()\">",
        "<table id=\"t\"><thead><tr>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 0)\">#</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 1)\">Title</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 2)\">Verdict</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 3)\">Priority</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 4)\">Group</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable('t', 5)\">Status</th>",
        "</tr></thead><tbody>",
        ([$rows[] | "<tr><td>#\(.number)</td><td>\(.title // ""|h)</td><td><span class=\"badge\">\(.verdict|h)</span></td><td><span class=\"badge badge-priority-\(.priority|h)\">\(.priority|h)</span></td><td>\(.group|h)</td><td>\(.status // "PENDING"|h)</td></tr>"] | join("")),
        "</tbody></table>",
        "<script>",
        "function groomFilterTable(inputId, tableId) {",
        "  var input = document.getElementById(inputId);",
        "  if (!input) return;",
        "  var q = input.value.toLowerCase();",
        "  var rows = document.querySelectorAll(\"#\" + tableId + \" tbody tr\");",
        "  for (var i = 0; i < rows.length; i++) {",
        "    var t = rows[i].textContent.toLowerCase();",
        "    rows[i].hidden = q.length > 0 && t.indexOf(q) === -1;",
        "  }",
        "}",
        "function groomFilter() {",
        "  groomFilterTable(\"q\", \"t\");",
        "}",
        "var sortDirections = {};",
        "function groomSortTable(tableId, colIndex) {",
        "  var table = document.getElementById(tableId);",
        "  if (!table) return;",
        "  var tbody = table.querySelector(\"tbody\");",
        "  if (!tbody) return;",
        "  var rows = Array.from(tbody.querySelectorAll(\"tr\"));",
        "  var key = tableId + \"-\" + colIndex;",
        "  var dir = sortDirections[key] === \"asc\" ? \"desc\" : \"asc\";",
        "  sortDirections[key] = dir;",
        "  rows.sort(function(a, b) {",
        "    var aCell = a.children[colIndex];",
        "    var bCell = b.children[colIndex];",
        "    var aText = aCell ? aCell.textContent.trim() : \"\";",
        "    var bText = bCell ? bCell.textContent.trim() : \"\";",
        "    var aNum = parseFloat(aText.replace(/^[#]/, \"\"));",
        "    var bNum = parseFloat(bText.replace(/^[#]/, \"\"));",
        "    if (!isNaN(aNum) && !isNaN(bNum)) {",
        "      return dir === \"asc\" ? aNum - bNum : bNum - aNum;",
        "    }",
        "    return dir === \"asc\" ? aText.localeCompare(bText) : bText.localeCompare(aText);",
        "  });",
        "  for (var i = 0; i < rows.length; i++) {",
        "    tbody.appendChild(rows[i]);",
        "  }",
        "}",
        "</script>"
    ' "$dispositions" >"$out_html"

    echo "groom-report: wrote $out_html and $out_md"
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
render) cmd_render "$@" ;;
*) usage ;;
esac
