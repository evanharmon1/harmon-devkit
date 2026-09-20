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
# Masthead (repo, generation stamp, headline counts and a proportional
# close/decide/needs-info/keep ribbon for the whole backlog);
# Stats strip; Visualizations (inline SVG/CSS charts in HTML — a verdict
# donut with a percentage legend, a proportional priority bar carrying the
# disposition split inside each band, an age-histogram column chart, and
# tracked evidence bars); What to do next;
# Close now (table, every entry showing number AND title); Milestones;
# Parent issues; Spec-worthy themes; Decisions (ranked into top five, next
# ten, remainder by area with callouts and response lines); Completed this run;
# Process findings (two-column table); Conformance; Bot-owned issues; Unverified (only when
# the dataset carries any — stats.unverified, from groom-verdicts.sh join
# --allow-missing); Every issue (full table with inline filter/search).
#
# The HTML is one self-contained file: no external stylesheet, font, image or
# script, and no library — every chart is inline SVG or CSS box geometry
# computed here in jq, and the only script is the ~40 lines of vanilla table
# sort/filter at the end. That is what lets the same file be published as an
# Artifact, mailed, or opened from disk with no network at all. Colour is
# load-bearing rather than decorative: the verdict family (close / keep /
# decision / needs-info) and the priority band each own a hue, and that hue
# means the same thing everywhere it appears — ribbon, donut, badges, column
# charts. Both palettes are CSS variables on :root with a
# prefers-color-scheme override, so the report is legible in either theme
# with no toggle to persist (nothing here may depend on stored state).
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
             # Normalize the string-typed fields at the boundary rather than at
             # each use. `join` validates the vocabulary, but a hand-made
             # dataset with a null verdict otherwise aborts the whole render on
             # the first `startswith` — and a report renderer must not be the
             # thing that crashes on its own input.
             . + {verdict: (.verdict // "" | tostring),
                  priority: (.priority // "" | tostring),
                  group: (.group // "" | tostring)}
             | ($outcomes_map[(.number|tostring)] // {}) as $ops
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
      | ($d.conformance_defects // []) as $conf_defects

      # Ranking decisions: priority (P0 > P1 > P2 > P3), blocking count (descending), age (descending)
      | ($decisions | sort_by([ pscore, (- (.blocking_count // .blocked_by_count // 0)), (- (.age_days // 0)), .number ])) as $decisions_ranked
      | ($decisions_ranked[0:5]) as $top_five
      | ($decisions_ranked[5:15]) as $next_ten
      | ($decisions_ranked[15:]) as $remainder

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
        "- Pre-audit triage pass: \($stats.pre_audit_triage // "not run")",
        "",
        "## What to do next",
        "",
        (if ($close|length) > 0 then "1. Review \($close|length) close candidate(s) below." else empty end),
        (if ($decisions|length) > 0 then "1. Answer \($decisions|length) decision(s) below." else empty end),
        (if ($themes|length) > 0 then "1. Review \($themes|length) spec-worthy theme proposal(s) below." else empty end),
        (if ($findings|length) > 0 then "1. Review \($findings|length) process finding(s) below." else empty end),
        (if ($conf_defects|length) > 0 then "1. Resolve \($conf_defects|length) conformance defect(s) below." else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($themes|length) == 0 and ($findings|length) == 0
            and ($conf_defects|length) == 0 and ($unverified|length) == 0
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
        "## Conformance",
        "",
        (if ($conf_defects|length) == 0 then "None recorded this run."
         else (
           ($conf_defects | group_by(.kind // "Other")[] |
            "### \(.[0].kind // "Other" | mdesc)",
            "",
            (.[] | "- #\(.number) — \(.title // (ititle($titles; .number) | sub("^#[0-9]+ "; "")) | mdesc) — \(.defect | mdesc) (proposed fix: \(.fix | mdesc))"),
            ""
           )
         )
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
      # Issue reference as a monospace pill that links to the issue on GitHub,
      # followed by its title. Same "number AND title, always" contract as
      # ititle_h (issue #1015) — the link is presentation only, and the plain
      # ititle_h is still used wherever a link would be noise.
      def ilink_h(titles; repo; n):
        "<a class=\"inum\" href=\"https://github.com/" + (repo|h) + "/issues/" + (n|tostring) + "\">#" + (n|tostring) + "</a> "
        + "<span class=\"ititle\">" + (titles[(n|tostring)] // "(title unavailable)" | h) + "</span>";
      def format_verdict_h(titles):
        if test("^CLOSE-dup-of-#[0-9]+$") then
          capture("^CLOSE-dup-of-#(?<t>[0-9]+)$").t as $t |
          "CLOSE-dup-of-#" + $t + " — " + (titles[$t] // "(title unavailable)" | h)
        else
          (. | h)
        end;
      # Verdict family drives the badge colour: closes read red, keeps green,
      # decisions blue, info slate. A neutral badge for every verdict (the
      # pre-#1096 rendering) made the one column a reader scans for carry no
      # signal at all.
      def vclass:
        # tostring first: the pre-#1096 rendering passed every verdict through
        # `h` (which coerces), so a hand-made dataset carrying a null verdict
        # rendered rather than aborting the run. `join` validates the
        # vocabulary, but this file must not be the thing that crashes.
        (. | tostring)
        | if startswith("CLOSE-") then "v-close"
        elif . == "KEEP" then "v-keep"
        elif . == "NEEDS-DECISION" then "v-decision"
        else "v-info" end;
      def vbadge(titles): "<span class=\"badge badge-" + (. | vclass) + "\">" + (. | format_verdict_h(titles)) + "</span>";
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
      def pbadge: "<span class=\"badge badge-priority-" + (.priority|h) + "\">" + (.priority|h) + "</span>";
      # One decimal place, computed from integers only so the render stays
      # byte-identical for an unchanged dataset (issue #1015).
      def pct(total): if total == 0 then 0 else ((. * 1000 / total) | round) / 10 end;

      . as $d
      | ($d.dispositions // []
         | map(
             # Normalize the string-typed fields at the boundary rather than at
             # each use. `join` validates the vocabulary, but a hand-made
             # dataset with a null verdict otherwise aborts the whole render on
             # the first `startswith` — and a report renderer must not be the
             # thing that crashes on its own input.
             . + {verdict: (.verdict // "" | tostring),
                  priority: (.priority // "" | tostring),
                  group: (.group // "" | tostring)}
             | ($outcomes_map[(.number|tostring)] // {}) as $ops
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
      | ($d.conformance_defects // []) as $conf_defects
      # $audited is what carries a verdict this run; $total is the backlog.
      # Under `join --allow-missing` they differ, and every proportion — the
      # ribbon, the donut, the stat meters — must be drawn against the backlog
      # or an incomplete audit reads as complete coverage (Codex/Greptile on
      # PR #1101). Sections that can only list verified rows still count
      # $audited, because that is what they actually show.
      | ($rows | length) as $audited
      | ($unverified | length) as $unverified_n
      | ($audited + $unverified_n) as $total

      # Ranking decisions: priority (P0 > P1 > P2 > P3), blocking count (descending), age (descending)
      | ($decisions | sort_by([ pscore, (- (.blocking_count // .blocked_by_count // 0)), (- (.age_days // 0)), .number ])) as $decisions_ranked
      | ($decisions_ranked[0:5]) as $top_five
      | ($decisions_ranked[5:15]) as $next_ten
      | ($decisions_ranked[15:]) as $remainder

      # ── Masthead ribbon: the whole backlog as one proportional bar ──
      | [
          # Each segment counts exactly what its link lands on: Close now and
          # Decisions list PENDING rows only, so counting the whole family
          # here rendered "Close 3" over a section reading "None this run"
          # once outcomes were merged (Codex on PR #1101).
          { label: "Close", count: ($close|length), color: "#d1242f", href: "#close" },
          { label: "Decide", count: ($decisions|length), color: "#0969da", href: "#decisions" },
          { label: "Settled", count: (($close_done|length) + ($decisions_done|length)), color: "#57606a", href: "#completed" },
          { label: "Needs info", count: ([$rows[] | select(.verdict == "NEEDS-INFO")] | length), color: "#8250df", href: "#every-issue" },
          { label: "Keep", count: ([$rows[] | select(.verdict == "KEEP")] | length), color: "#1a7f37", href: "#every-issue" },
          { label: "Unverified", count: $unverified_n, color: "#adb5bd", href: "#unverified" }
        ] as $ribbon

      # ── Inline SVG Chart 1: Verdict breakdown (donut) ──
      | [
          { label: "CLOSE-done", count: ([$rows[] | select(.verdict == "CLOSE-done")] | length), color: "#d1242f" },
          { label: "CLOSE-obsolete", count: ([$rows[] | select(.verdict == "CLOSE-obsolete")] | length), color: "#bc4c00" },
          { label: "CLOSE-dup", count: ([$rows[] | select(.verdict | startswith("CLOSE-dup"))] | length), color: "#a40e26" },
          { label: "CLOSE-wrong-repo", count: ([$rows[] | select(.verdict | startswith("CLOSE-wrong-repo"))] | length), color: "#bf8700" },
          { label: "KEEP", count: ([$rows[] | select(.verdict == "KEEP")] | length), color: "#1a7f37" },
          { label: "NEEDS-DECISION", count: ([$rows[] | select(.verdict == "NEEDS-DECISION")] | length), color: "#0969da" },
          { label: "NEEDS-INFO", count: ([$rows[] | select(.verdict == "NEEDS-INFO")] | length), color: "#57606a" },
          { label: "Unverified", count: $unverified_n, color: "#adb5bd" }
        ] as $v_data
      | (([$v_data[].count] | max) // 1) as $v_max0
      | (if $v_max0 == 0 then 1 else $v_max0 end) as $v_max
      # Donut geometry: r=44 gives a circumference of 2*pi*44 = 276.46. Each
      # slice is drawn as a stroked arc via stroke-dasharray, so no trig (and
      # no floating-point path data) is needed and the render stays stable.
      | 276.46 as $circ
      | ([foreach $v_data[] as $it (0; . + $it.count; {item: $it, cum: .})]) as $v_seg

      # ── Inline SVG Chart 2: Priority mix ──
      | [
          { label: "High", count: ([$rows[] | select((.priority // "") | test("(?i)^p[01]$|high"))] | length), color: "#d1242f" },
          { label: "Medium", count: ([$rows[] | select((.priority // "") | test("(?i)^p2$|medium"))] | length), color: "#bf8700" },
          { label: "Low", count: ([$rows[] | select((.priority // "") | test("(?i)^p3$|low"))] | length), color: "#0969da" }
        ] as $p_data
      | (([$p_data[].count] | max) // 1) as $p_max0
      | (if $p_max0 == 0 then 1 else $p_max0 end) as $p_max
      | ([$p_data[].count] | add // 0) as $p_total
      # Disposition split within each priority band — the priority card
      # otherwise shows one bar and a lot of white space, and "how much of the
      # high-priority work is actually a close candidate" is the question a
      # reader asks next.
      | ([ { label: "High", re: "(?i)^p[01]$|high" },
           { label: "Medium", re: "(?i)^p2$|medium" },
           { label: "Low", re: "(?i)^p3$|low" } ]
         | map(. as $b
           | ([$rows[] | select((.priority // "") | test($b.re))]) as $sub
           | { label: $b.label, total: ($sub | length),
               parts: [
                 { label: "Close", count: ([$sub[] | select(.verdict | startswith("CLOSE-"))] | length), color: "#d1242f" },
                 { label: "Decide", count: ([$sub[] | select(.verdict == "NEEDS-DECISION")] | length), color: "#0969da" },
                 { label: "Needs info", count: ([$sub[] | select(.verdict == "NEEDS-INFO")] | length), color: "#8250df" },
                 { label: "Keep", count: ([$sub[] | select(.verdict == "KEEP")] | length), color: "#1a7f37" }
               ] })) as $p_matrix

      # ── Inline SVG Chart 3: Backlog age distribution ──
      | [
          { label: "< 30d", count: ([$rows[] | select((.age_days // 0) < 30)] | length), color: "#1a7f37" },
          { label: "30–90d", count: ([$rows[] | select((.age_days // 0) >= 30 and (.age_days // 0) <= 90)] | length), color: "#0969da" },
          { label: "90–180d", count: ([$rows[] | select((.age_days // 0) > 90 and (.age_days // 0) <= 180)] | length), color: "#bf8700" },
          { label: "180–365d", count: ([$rows[] | select((.age_days // 0) > 180 and (.age_days // 0) <= 365)] | length), color: "#bc4c00" },
          { label: "> 365d", count: ([$rows[] | select((.age_days // 0) > 365)] | length), color: "#d1242f" }
        ] as $a_data
      | (([$a_data[].count] | max) // 1) as $a_max0
      | (if $a_max0 == 0 then 1 else $a_max0 end) as $a_max

      # ── Inline SVG Chart 4: Closes by evidence type ──
      | [
          { label: "Duplicate link", count: ([$close_all[] | select((.verdict | startswith("CLOSE-dup-of-")) or ((.evidence // "") | test("(?i)\\bdup(licate)?\\b|#[0-9]+")))] | length), color: "#8250df" },
          { label: "Merged PR", count: ([$close_all[] | select(((.verdict | startswith("CLOSE-dup-of-")) | not) and (((.evidence // "") | test("(?i)\\bdup(licate)?\\b|#[0-9]+") | not)) and ((.evidence // "") | test("(?i)\\b(pull request|pull|pr)\\b|\\bmerged\\b")))] | length), color: "#1a7f37" },
          { label: "Commit / SHA", count: ([$close_all[] | select(((.verdict | startswith("CLOSE-dup-of-")) | not) and (((.evidence // "") | test("(?i)\\bdup(licate)?\\b|#[0-9]+") | not)) and (((.evidence // "") | test("(?i)\\b(pull request|pull|pr)\\b|\\bmerged\\b") | not)) and ((.evidence // "") | test("(?i)\\b(commit|sha)\\b|[0-9a-f]{7,40}")))] | length), color: "#0969da" },
          { label: "File:line", count: ([$close_all[] | select(((.verdict | startswith("CLOSE-dup-of-")) | not) and (((.evidence // "") | test("(?i)\\bdup(licate)?\\b|#[0-9]+") | not)) and (((.evidence // "") | test("(?i)\\b(pull request|pull|pr)\\b|\\bmerged\\b|\\b(commit|sha)\\b|[0-9a-f]{7,40}") | not)) and ((.evidence // "") | test("(?i):[0-9]+|/|\\.[a-z]+:")))] | length), color: "#bf8700" },
          { label: "Other / target", count: ([$close_all[] | select(((.verdict | startswith("CLOSE-dup-of-")) | not) and (((.evidence // "") | test("(?i)\\bdup(licate)?\\b|#[0-9]+") | not)) and (((.evidence // "") | test("(?i)\\b(pull request|pull|pr)\\b|\\bmerged\\b|\\b(commit|sha)\\b|[0-9a-f]{7,40}|:[0-9]+|/|\\.[a-z]+:") | not)))] | length), color: "#57606a" }
        ] as $e_data
      | (([$e_data[].count] | max) // 1) as $e_max0
      | (if $e_max0 == 0 then 1 else $e_max0 end) as $e_max

      | "<!doctype html><meta charset=\"utf-8\">",
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
        "<title>Groom report — \($repo|h)</title>",
        "<style>",
        ":root {",
        "  --bg: #f4f6fb;",
        "  --surface: #ffffff;",
        "  --surface-2: #f6f8fa;",
        "  --text: #0d1117;",
        "  --muted: #5b6672;",
        "  --border: #e1e7ef;",
        "  --th-bg: #f0f3f8;",
        "  --callout-bg: #eef4ff;",
        "  --callout-border: #4f46e5;",
        "  --card-bg: #ffffff;",
        "  --nav-bg: rgba(255,255,255,0.92);",
        "  --link: #3538cd;",
        "  --badge-bg: #eaeef3;",
        "  --badge-text: #24292f;",
        "  --accent: #4f46e5;",
        "  --accent-2: #06b6d4;",
        "  --ok: #1a7f37;",
        "  --warn: #bf8700;",
        "  --danger: #d1242f;",
        "  --info: #0969da;",
        "  --purple: #8250df;",
        "  --track: #e6ebf2;",
        "  --shadow: 0 1px 2px rgba(16,24,40,0.05), 0 8px 24px -12px rgba(16,24,40,0.18);",
        "  --navh: 2.7rem;",
        "  --hero-1: #312e81;",
        "  --hero-2: #1e1b4b;",
        "  --hero-3: #0b1020;",
        "}",
        "@media (prefers-color-scheme: dark) {",
        "  :root {",
        "    --bg: #0a0d12;",
        "    --surface: #11161d;",
        "    --surface-2: #161c24;",
        "    --text: #e6edf3;",
        "    --muted: #94a3b2;",
        "    --border: #222b36;",
        "    --th-bg: #161c24;",
        "    --callout-bg: #161c2e;",
        "    --callout-border: #7c7cf5;",
        "    --card-bg: #11161d;",
        "    --nav-bg: rgba(13,17,23,0.92);",
        "    --link: #9b9bff;",
        "    --badge-bg: #1c232c;",
        "    --badge-text: #c9d1d9;",
        "    --accent: #8b8bfa;",
        "    --accent-2: #22d3ee;",
        "    --ok: #3fb950;",
        "    --warn: #d29922;",
        "    --danger: #ff7b72;",
        "    --info: #58a6ff;",
        "    --purple: #bc8cff;",
        "    --track: #1e2630;",
        "    --shadow: 0 1px 2px rgba(0,0,0,0.4), 0 10px 30px -14px rgba(0,0,0,0.8);",
        "    --hero-1: #1e1b4b;",
        "    --hero-2: #111a33;",
        "    --hero-3: #05070d;",
        "  }",
        "}",
        "* { box-sizing: border-box; }",
        "html { scroll-behavior: smooth; scroll-padding-top: calc(var(--navh) + 1rem); }",
        "body { font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif; margin: 0; color: var(--text); background: var(--bg); line-height: 1.55; -webkit-font-smoothing: antialiased; }",
        "main { max-width: 1180px; margin: 0 auto; padding: 0 1.5rem 5rem; counter-reset: sect; }",
        "a { color: var(--link); }",
        "h1 { font-size: clamp(1.9rem, 4vw, 2.9rem); line-height: 1.1; letter-spacing: -0.035em; font-weight: 800; margin: 0.2rem 0 0.4rem; }",
        "h2 { font-size: 1.3rem; letter-spacing: -0.02em; font-weight: 750; margin: 3rem 0 1rem; display: flex; align-items: center; gap: 0.6rem; }",
        "h2::before { counter-increment: sect; content: counter(sect, decimal-leading-zero); font-size: 0.72rem; font-weight: 700; letter-spacing: 0.1em; color: var(--accent); background: var(--callout-bg); border: 1px solid var(--border); border-radius: 999px; padding: 0.2rem 0.55rem; font-variant-numeric: tabular-nums; }",
        "h2::after { content: \"\"; flex: 1; height: 1px; background: linear-gradient(90deg, var(--border), transparent); }",
        "details.sect { margin: 0; }",
        "details.sect > summary { list-style: none; cursor: pointer; border-radius: 12px; margin: 0 -0.75rem; padding: 0 0.75rem; }",
        "details.sect > summary::-webkit-details-marker { display: none; }",
        "details.sect > summary:hover { background: var(--surface-2); }",
        "details.sect > summary:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }",
        "details.sect > summary > h2 { margin: 1.15rem 0; }",
        "details.sect[open] > summary > h2 { margin: 2.4rem 0 0.9rem; }",
        "details.sect[open] { margin-bottom: 1.6rem; }",
        "details.sect > *:not(summary):last-child { margin-bottom: 0; }",
        # the affordance says what it does in words, not a glyph alone: a
        # collapsed section is the default here, so a reader meeting the
        # report for the first time has to be told these open.
        ".chev { flex: none; font-size: 0.64rem; font-weight: 800; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); background: var(--surface-2); border: 1px solid var(--border); border-radius: 999px; padding: 0.15rem 0.55rem; white-space: nowrap; }",
        ".chev::after { content: \"Show ▸\"; }",
        "details.sect[open] > summary > h2 > .chev::after { content: \"Hide ▾\"; }",
        "details.sect > summary:hover > h2 > .chev { border-color: var(--accent); color: var(--accent); }",
        "a.stat-card { display: block; color: inherit; text-decoration: none; transition: transform 0.12s ease, border-color 0.12s ease; }",
        "a.stat-card:hover { transform: translateY(-2px); border-color: var(--rail, var(--accent)); }",
        "a.stat-card:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }",
        ".stat-foot .go { display: block; color: var(--rail, var(--accent)); font-weight: 700; opacity: 0; transition: opacity 0.12s ease; }",
        "a.stat-card:hover .go, a.stat-card:focus-visible .go { opacity: 1; }",
        "@media (hover: none) { .stat-foot .go { opacity: 1; } }",
        "ol.todo li a { color: inherit; text-decoration: none; flex: 1; }",
        "ol.todo li:hover { border-left-color: var(--accent-2); }",
        "ol.todo li a:hover { text-decoration: underline; }",
        "ol.todo li a::after { content: \" →\"; color: var(--accent); }",
        ".ribbon-legend a { color: inherit; text-decoration: none; border-bottom: 1px solid transparent; }",
        ".ribbon-legend a:hover { border-bottom-color: currentColor; }",
        "h3 { font-size: 1rem; letter-spacing: -0.01em; margin: 1.5rem 0 0.6rem; font-weight: 700; }",
        "h4 { font-size: 0.85rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); margin: 1.4rem 0 0.5rem; }",
        "p { margin: 0.5rem 0; }",
        # Sticky section nav
        "nav.nav { position: sticky; top: 0; z-index: 100; display: flex; flex-wrap: nowrap; overflow-x: auto; scrollbar-width: none; gap: 0.25rem; height: var(--navh); align-items: center; padding: 0 max(1.5rem, calc((100vw - 1180px) / 2)); background: var(--nav-bg); backdrop-filter: blur(10px); border-bottom: 1px solid var(--border); font-size: 0.78rem; }",
        "nav.nav::-webkit-scrollbar { display: none; }",
        "nav.nav a { color: var(--muted); text-decoration: none; font-weight: 600; padding: 0.25rem 0.55rem; border-radius: 999px; white-space: nowrap; }",
        "nav.nav a:hover { color: var(--text); background: var(--surface-2); }",
        # Masthead
        ".hero { background: radial-gradient(1000px 420px at 12% -30%, rgba(99,102,241,0.55), transparent 60%), radial-gradient(760px 360px at 88% 0%, rgba(6,182,212,0.35), transparent 62%), linear-gradient(135deg, var(--hero-1), var(--hero-2) 46%, var(--hero-3)); color: #f8fafc; padding: 2.75rem 0 2.25rem; margin-bottom: 0.5rem; }",
        ".hero-inner { max-width: 1180px; margin: 0 auto; padding: 0 1.5rem; }",
        ".eyebrow { font-size: 0.72rem; font-weight: 700; letter-spacing: 0.22em; text-transform: uppercase; color: #a5b4fc; margin: 0; }",
        ".hero h1 { color: #ffffff; }",
        ".hero-meta { color: #c7d2e5; font-size: 0.86rem; margin: 0 0 1.4rem; font-variant-numeric: tabular-nums; }",
        ".hero-meta .dot { opacity: 0.45; margin: 0 0.5rem; }",
        ".ribbon { display: flex; height: 16px; border-radius: 999px; overflow: hidden; background: rgba(255,255,255,0.12); box-shadow: inset 0 0 0 1px rgba(255,255,255,0.12); }",
        ".ribbon span { display: block; height: 100%; }",
        ".ribbon-legend { display: flex; flex-wrap: wrap; gap: 1.1rem; margin-top: 0.7rem; font-size: 0.78rem; color: #dbe3f1; }",
        ".ribbon-legend b { color: #ffffff; font-variant-numeric: tabular-nums; }",
        ".swatch { display: inline-block; width: 9px; height: 9px; border-radius: 3px; margin-right: 0.4rem; vertical-align: 0; }",
        # Stat cards
        ".stats-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 1rem; margin: 1rem 0 0.5rem; }",
        ".stat-card { position: relative; background: var(--card-bg); border: 1px solid var(--border); border-radius: 14px; padding: 1.05rem 1.1rem 1rem; box-shadow: var(--shadow); overflow: hidden; }",
        ".stat-card::before { content: \"\"; position: absolute; inset: 0 0 auto 0; height: 4px; background: var(--rail, var(--accent)); }",
        ".stat-num { font-size: 2.3rem; font-weight: 800; letter-spacing: -0.045em; line-height: 1.05; font-variant-numeric: tabular-nums; color: var(--text); }",
        ".stat-num.is-text { font-size: 1.3rem; letter-spacing: -0.02em; }",
        ".stat-label { font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.09em; color: var(--muted); margin-top: 0.2rem; }",
        ".stat-meter { height: 5px; border-radius: 999px; background: var(--track); margin-top: 0.7rem; overflow: hidden; }",
        ".stat-meter i { display: block; height: 100%; background: var(--rail, var(--accent)); border-radius: 999px; }",
        ".stat-foot { font-size: 0.72rem; color: var(--muted); margin-top: 0.4rem; font-variant-numeric: tabular-nums; }",
        # Charts
        ".charts-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(420px, 100%), 1fr)); gap: 1rem; margin: 1rem 0; }",
        ".chart-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 14px; padding: 1.1rem 1.2rem 1.2rem; box-shadow: var(--shadow); }",
        ".chart-card h3 { margin: 0 0 0.9rem; font-size: 0.74rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); }",
        ".chart-split { display: flex; align-items: center; gap: 1.1rem; flex-wrap: wrap; }",
        ".donut { width: 124px; height: 124px; flex: none; }",
        ".donut-num { font-size: 26px; font-weight: 800; text-anchor: middle; fill: currentColor; letter-spacing: -1px; }",
        ".donut-cap { font-size: 8.5px; text-anchor: middle; fill: currentColor; opacity: 0.6; letter-spacing: 1.2px; text-transform: uppercase; }",
        ".legend { list-style: none; margin: 0; padding: 0; flex: 1 1 200px; min-width: 200px; font-size: 0.78rem; }",
        ".legend li { display: grid; grid-template-columns: 1fr auto auto; align-items: center; gap: 0.5rem; padding: 0.17rem 0; }",
        ".legend .lg-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }",
        ".legend b { font-variant-numeric: tabular-nums; }",
        ".legend .lg-pct { color: var(--muted); font-variant-numeric: tabular-nums; min-width: 3.1rem; text-align: right; }",
        ".legend li.is-zero { opacity: 0.42; }",
        ".stackbar { display: flex; height: 40px; border-radius: 10px; overflow: hidden; background: var(--track); }",
        ".stackbar span { display: flex; align-items: center; justify-content: center; color: #fff; font-size: 0.8rem; font-weight: 700; font-variant-numeric: tabular-nums; text-shadow: 0 1px 2px rgba(0,0,0,0.3); }",
        ".legend-row { display: flex; gap: 1.1rem; flex-wrap: wrap; margin-top: 0.75rem; }",
        ".matrix { display: grid; gap: 0.5rem; margin-top: 1.1rem; }",
        ".matrix-cap { font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.09em; color: var(--muted); font-weight: 700; }",
        ".matrix-row { display: grid; grid-template-columns: 4.4rem 1fr 2.2rem; align-items: center; gap: 0.6rem; font-size: 0.76rem; }",
        ".matrix-row b { font-variant-numeric: tabular-nums; text-align: right; }",
        ".minibar { display: flex; height: 10px; border-radius: 999px; overflow: hidden; background: var(--track); }",
        ".minibar span { display: block; height: 100%; }",
        ".legend-row span { white-space: nowrap; }",
        "svg text { font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, \"Segoe UI\", Roboto, sans-serif; font-size: 11px; fill: currentColor; }",
        "svg .axis { stroke: var(--border); stroke-width: 1; }",
        "svg .grid { stroke: var(--border); stroke-width: 1; stroke-dasharray: 2 4; opacity: 0.8; }",
        "svg .val { font-weight: 700; font-variant-numeric: tabular-nums; }",
        "svg .cap { opacity: 0.68; }",
        "svg .track { fill: var(--track); }",
        # Action list
        "ol.todo { list-style: none; counter-reset: todo; margin: 0.5rem 0 0; padding: 0; display: grid; gap: 0.55rem; }",
        "ol.todo li { counter-increment: todo; display: flex; gap: 0.85rem; align-items: flex-start; background: var(--card-bg); border: 1px solid var(--border); border-left: 4px solid var(--accent); border-radius: 12px; padding: 0.8rem 1rem; box-shadow: var(--shadow); font-weight: 550; }",
        "ol.todo li::before { content: counter(todo); flex: none; width: 1.55rem; height: 1.55rem; border-radius: 50%; background: var(--accent); color: #fff; font-size: 0.78rem; font-weight: 800; display: grid; place-items: center; font-variant-numeric: tabular-nums; }",
        "ol.todo li.is-clean { border-left-color: var(--ok); }",
        "ol.todo li.is-clean::before { background: var(--ok); content: \"✓\"; }",
        # Tables
        ".table-wrap { border: 1px solid var(--border); border-radius: 14px; background: var(--card-bg); box-shadow: var(--shadow); }",
        "table thead tr:first-child th:first-child { border-top-left-radius: 13px; }",
        "table thead tr:first-child th:last-child { border-top-right-radius: 13px; }",
        "table tbody tr:last-child td:first-child { border-bottom-left-radius: 13px; }",
        "table tbody tr:last-child td:last-child { border-bottom-right-radius: 13px; }",
        "table { border-collapse: separate; border-spacing: 0; width: 100%; font-size: 0.855rem; }",
        "th, td { text-align: left; padding: 0.6rem 0.8rem; border-bottom: 1px solid var(--border); vertical-align: top; }",
        "th { background: var(--th-bg); position: sticky; top: var(--navh); z-index: 2; font-size: 0.68rem; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted); font-weight: 700; white-space: nowrap; }",
        "tbody tr:nth-child(even) { background: var(--surface-2); }",
        "tbody tr:hover { background: var(--callout-bg); }",
        "tbody tr:last-child td { border-bottom: 0; }",
        "th.sortable { cursor: pointer; user-select: none; }",
        "th.sortable::after { content: \" ⇅\"; opacity: 0.4; }",
        "th.sortable:hover { color: var(--text); }",
        ".searchbar { display: flex; align-items: center; gap: 0.6rem; margin: 0.5rem 0 0.8rem; }",
        "input[type=search] { padding: 0.55rem 0.85rem; width: 100%; max-width: 26rem; border: 1px solid var(--border); border-radius: 999px; background: var(--surface); color: var(--text); font-size: 0.85rem; box-shadow: var(--shadow); }",
        "input[type=search]:focus { outline: 2px solid var(--accent); outline-offset: 1px; }",
        ".inum { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.8em; font-weight: 700; text-decoration: none; color: var(--link); background: var(--badge-bg); border-radius: 6px; padding: 0.08rem 0.35rem; white-space: nowrap; }",
        ".inum:hover { background: var(--accent); color: #fff; }",
        ".ititle { font-weight: 600; }",
        "td.ititle { min-width: 15rem; }",
        # Callouts + badges
        ".callout { background: var(--callout-bg); border-left: 4px solid var(--callout-border); padding: 0.7rem 0.95rem; margin: 0.6rem 0; border-radius: 0 10px 10px 0; }",
        ".callout-title { font-size: 0.68rem; font-weight: 800; text-transform: uppercase; letter-spacing: 0.1em; color: var(--callout-border); margin-bottom: 0.15rem; }",
        ".callout-body { margin: 0.2rem 0; }",
        ".callout-response { font-size: 0.79rem; color: var(--muted); margin: 0.45rem 0 0; }",
        ".badge { display: inline-block; padding: 0.15rem 0.5rem; font-size: 0.7rem; font-weight: 700; letter-spacing: 0.01em; border-radius: 999px; background: var(--badge-bg); color: var(--badge-text); white-space: nowrap; }",
        ".badge-v-close { background: #ffe9e6; color: #a40e26; }",
        ".badge-v-keep { background: #dcfce7; color: #15803d; }",
        ".badge-v-decision { background: #dbeafe; color: #1d4ed8; }",
        ".badge-v-info { background: #ede9fe; color: #6d28d9; }",
        ".badge-priority-high, .badge-priority-p0, .badge-priority-p1, .badge-priority-P0, .badge-priority-P1, .badge-priority-urgent { background: #ffe9e6; color: #a40e26; }",
        ".badge-priority-medium, .badge-priority-p2, .badge-priority-P2 { background: #fff4d6; color: #8a5a00; }",
        ".badge-priority-low, .badge-priority-p3, .badge-priority-P3 { background: #e0edff; color: #1d4ed8; }",
        "@media (prefers-color-scheme: dark) {",
        "  .badge-v-close { background: #3d1013; color: #ff9c92; }",
        "  .badge-v-keep { background: #0d2a16; color: #56d364; }",
        "  .badge-v-decision { background: #111f3d; color: #79b8ff; }",
        "  .badge-v-info { background: #241a3d; color: #c6a8ff; }",
        "  .badge-priority-high, .badge-priority-p0, .badge-priority-p1, .badge-priority-P0, .badge-priority-P1, .badge-priority-urgent { background: #3d1013; color: #ff9c92; }",
        "  .badge-priority-medium, .badge-priority-p2, .badge-priority-P2 { background: #33260a; color: #e3b341; }",
        "  .badge-priority-low, .badge-priority-p3, .badge-priority-P3 { background: #111f3d; color: #79b8ff; }",
        "}",
        ".status { font-size: 0.7rem; font-weight: 700; border-radius: 999px; padding: 0.1rem 0.5rem; background: var(--badge-bg); color: var(--muted); white-space: nowrap; }",
        ".status-done { background: #dcfce7; color: #15803d; }",
        "@media (prefers-color-scheme: dark) { .status-done { background: #0d2a16; color: #56d364; } }",
        ".pill { font-size: 0.7rem; font-weight: 700; letter-spacing: 0.02em; background: var(--badge-bg); color: var(--muted); border-radius: 999px; padding: 0.1rem 0.5rem; font-variant-numeric: tabular-nums; }",
        ".card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 14px; padding: 1.1rem 1.2rem; margin: 0.8rem 0; box-shadow: var(--shadow); }",
        ".empty { color: var(--muted); font-style: italic; background: var(--surface-2); border: 1px dashed var(--border); border-radius: 12px; padding: 0.75rem 1rem; }",
        # Decisions
        ".decisions { display: grid; gap: 0.8rem; margin: 0.5rem 0; }",
        ".decision { display: grid; grid-template-columns: auto 1fr; gap: 0.9rem; background: var(--card-bg); border: 1px solid var(--border); border-radius: 14px; padding: 1rem 1.15rem; box-shadow: var(--shadow); }",
        ".rank { flex: none; width: 2.1rem; height: 2.1rem; border-radius: 12px; display: grid; place-items: center; font-weight: 800; font-size: 0.95rem; color: #fff; background: linear-gradient(140deg, var(--accent), var(--accent-2)); font-variant-numeric: tabular-nums; }",
        ".rank.plain { background: var(--badge-bg); color: var(--muted); }",
        ".decision-head { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: center; }",
        ".decision-head .ititle { font-size: 1rem; font-weight: 700; letter-spacing: -0.01em; }",
        ".decision-head .badge { margin-left: auto; }",
        ".decision-q { margin: 0.35rem 0 0; font-size: 0.95rem; }",
        ".meta-row { display: flex; flex-wrap: wrap; gap: 0.45rem; margin-top: 0.6rem; font-size: 0.72rem; color: var(--muted); }",
        ".chip { background: var(--surface-2); border: 1px solid var(--border); border-radius: 999px; padding: 0.1rem 0.5rem; font-variant-numeric: tabular-nums; }",
        ".chip-list { display: flex; flex-wrap: wrap; gap: 0.4rem; list-style: none; padding: 0; margin: 0.5rem 0; }",
        ".chip-list li { background: var(--card-bg); border: 1px solid var(--border); border-radius: 999px; padding: 0.25rem 0.7rem; font-size: 0.8rem; }",
        "ul.plain { list-style: none; padding: 0; margin: 0.5rem 0; display: grid; gap: 0.4rem; }",
        "ul.plain > li { background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; padding: 0.6rem 0.85rem; font-size: 0.87rem; }",
        "ul.plain > li.done::before { content: \"✓\"; color: var(--ok); font-weight: 800; margin-right: 0.5rem; }",
        "footer { max-width: 1180px; margin: 0 auto; padding: 2rem 1.5rem 3rem; color: var(--muted); font-size: 0.75rem; border-top: 1px solid var(--border); }",
        "@media (max-width: 900px) { .table-wrap { overflow-x: auto; } th { position: static; } }",
        "@media (max-width: 640px) { .hero { padding: 2rem 0 1.75rem; } .decision { grid-template-columns: 1fr; } }",
        "@media print { nav.nav { display: none; } .hero { background: #1e1b4b !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; } }",
        # Collapsed by default means a printed or PDF-exported report
        # would otherwise be summaries and nothing else. The beforeprint
        # handler below opens every section and restores it afterwards;
        # this rule is the fallback for print paths that fire no event.
        "@media print { details.sect > summary > h2 > .chev { display: none; } details.sect::details-content { content-visibility: visible !important; } }",
        "@media print { .table-wrap { overflow: visible; } th { position: static; } }",
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
        "<a href=\"#conformance\">Conformance</a>",
        "<a href=\"#bots\">Bot-owned</a>",
        "<a href=\"#every-issue\">Every issue</a>",
        "</nav>",
        "<header class=\"hero\"><div class=\"hero-inner\">",
        "<p class=\"eyebrow\">Backlog groom</p>",
        "<h1>Groom report — \($repo|h)</h1>",
        "<p class=\"hero-meta\">Generated \($now|h)<span class=\"dot\">•</span>\(if $unverified_n > 0 then "\($audited) of \($total) issue(s) audited" else "\($total) issue(s) audited" end)<span class=\"dot\">•</span>\($close|length) to close<span class=\"dot\">•</span>\($decisions|length) awaiting a decision</p>",
        "<div class=\"ribbon\">",
        ([$ribbon[] | select(.count > 0) | "<span style=\"width:\(.count | pct($total))%;background:\(.color)\" title=\"\(.label|h): \(.count)\"></span>"] | join("")),
        "</div>",
        "<div class=\"ribbon-legend\">",
        ([$ribbon[] | select(.count > 0 or .href != "#unverified") | "<a href=\"\(.href)\"><span class=\"swatch\" style=\"background:\(.color)\"></span>\(.label|h) <b>\(.count)</b></a>"] | join("")),
        "</div>",
        "</div></header>",
        "<main>",
        "<h2 id=\"stats\">Stats</h2>",
        "<div class=\"stats-strip\">",
        (if $unverified_n > 0 then
           "<a class=\"stat-card\" href=\"#unverified\" style=\"--rail: var(--accent)\"><div class=\"stat-num\">\($total)</div><div class=\"stat-label\">Open issues</div><div class=\"stat-meter\"><i style=\"width:\($audited | pct($total))%\"></i></div><div class=\"stat-foot\">\($audited) audited · \($unverified_n) unverified <span class=\"go\">Unverified →</span></div></a>"
         else
           "<a class=\"stat-card\" href=\"#every-issue\" style=\"--rail: var(--accent)\"><div class=\"stat-num\">\($total)</div><div class=\"stat-label\">Open issues</div><div class=\"stat-meter\"><i style=\"width:100%\"></i></div><div class=\"stat-foot\">audited this run <span class=\"go\">Every issue →</span></div></a>"
         end),
        "<a class=\"stat-card\" href=\"#close\" style=\"--rail: var(--danger)\"><div class=\"stat-num\">\($close|length)</div><div class=\"stat-label\">Close candidates</div><div class=\"stat-meter\"><i style=\"width:\(($close|length) | pct($audited))%\"></i></div><div class=\"stat-foot\">\(($close|length) | pct($audited))% of the \(if $unverified_n > 0 then "audited issues" else "backlog" end) <span class=\"go\">Close now →</span></div></a>",
        "<a class=\"stat-card\" href=\"#decisions\" style=\"--rail: var(--info)\"><div class=\"stat-num\">\($decisions|length)</div><div class=\"stat-label\">Decisions needed</div><div class=\"stat-meter\"><i style=\"width:\(($decisions|length) | pct($audited))%\"></i></div><div class=\"stat-foot\">\(($decisions|length) | pct($audited))% of the \(if $unverified_n > 0 then "audited issues" else "backlog" end) <span class=\"go\">Decisions →</span></div></a>",
        "<a class=\"stat-card\" href=\"#chart-priority\" style=\"--rail: var(--warn)\"><div class=\"stat-num\">\($stats.high_priority // 0)</div><div class=\"stat-label\">High priority</div><div class=\"stat-meter\"><i style=\"width:\(($stats.high_priority // 0) | pct($audited))%\"></i></div><div class=\"stat-foot\">\(($stats.high_priority // 0) | pct($audited))% of the \(if $unverified_n > 0 then "audited issues" else "backlog" end) <span class=\"go\">Priority mix →</span></div></a>",
        "<a class=\"stat-card\" href=\"#conformance\" style=\"--rail: var(--ok)\"><div class=\"stat-num is-text\">\($stats.pre_audit_triage // "not run"|h)</div><div class=\"stat-label\">Pre-audit triage</div><div class=\"stat-foot\">label coverage before the audit <span class=\"go\">Conformance →</span></div></a>",
        "</div>",
        "<h2 id=\"visualizations\">Visualizations</h2>",
        "<div class=\"charts-grid\">",
        # Chart 1: Verdict breakdown (donut + legend)
        "<div class=\"chart-card\" id=\"chart-verdicts\">",
        "<h3>Verdict breakdown</h3>",
        "<div class=\"chart-split\">",
        "<svg class=\"donut\" viewBox=\"0 0 120 120\" role=\"img\" aria-label=\"Verdict breakdown\">",
        "<title>Verdict breakdown</title>",
        "<circle cx=\"60\" cy=\"60\" r=\"44\" fill=\"none\" stroke=\"var(--track)\" stroke-width=\"20\" />",
        ([$v_seg[] | select(.item.count > 0) |
          ((.item.count * $circ / (if $total == 0 then 1 else $total end) * 100 | round) / 100) as $seg |
          (((.cum - .item.count) * $circ / (if $total == 0 then 1 else $total end) * 100 | round) / 100) as $off |
          "<circle cx=\"60\" cy=\"60\" r=\"44\" fill=\"none\" stroke=\"\(.item.color)\" stroke-width=\"20\" stroke-dasharray=\"\($seg) \($circ)\" stroke-dashoffset=\"-\($off)\" transform=\"rotate(-90 60 60)\"><title>\(.item.label|h): \(.item.count)</title></circle>"
         ] | join("")),
        "<text class=\"donut-num\" x=\"60\" y=\"62\">\($total)</text>",
        "<text class=\"donut-cap\" x=\"60\" y=\"75\">issues</text>",
        "</svg>",
        "<ul class=\"legend\">",
        ([$v_data[] |
          "<li class=\"\(if .count == 0 then "is-zero" else "" end)\"><span class=\"lg-label\"><span class=\"swatch\" style=\"background:\(.color)\"></span>\(.label|h)</span><b>\(.count)</b><span class=\"lg-pct\">\(.count | pct($total))%</span></li>"
         ] | join("")),
        "</ul>",
        "</div>",
        "</div>",
        # Chart 2: Priority mix (proportional stacked bar)
        "<div class=\"chart-card\" id=\"chart-priority\">",
        "<h3>Priority mix</h3>",
        "<div class=\"stackbar\">",
        ([$p_data[] | select(.count > 0) | "<span style=\"width:\(.count | pct($p_total))%;background:\(.color)\" title=\"\(.label|h): \(.count)\">\(.count)</span>"] | join("")),
        "</div>",
        "<div class=\"legend-row\">",
        ([$p_data[] | "<span><span class=\"swatch\" style=\"background:\(.color)\"></span>\(.label|h) <b>\(.count)</b> <span class=\"lg-pct\">\(.count | pct($p_total))%</span></span>"] | join("")),
        "</div>",
        "<div class=\"matrix\">",
        "<div class=\"matrix-cap\">Disposition within each band</div>",
        ([$p_matrix[] | . as $band | ($band.total) as $bt |
          "<div class=\"matrix-row\"><span>\($band.label|h)</span><div class=\"minibar\">"
          + ([$band.parts[] | select(.count > 0) | "<span style=\"width:\(.count | pct($bt))%;background:\(.color)\" title=\"\(.label|h): \(.count)\"></span>"] | join(""))
          + "</div><b>\($bt)</b></div>"] | join("")),
        "</div>",
        "</div>",
        # Chart 3: Backlog age distribution (column histogram)
        "<div class=\"chart-card\" id=\"chart-age\">",
        "<h3>Backlog age distribution</h3>",
        "<svg viewBox=\"0 0 380 170\" width=\"100%\" height=\"170\" role=\"img\" aria-label=\"Backlog age distribution\">",
        "<title>Backlog age distribution</title>",
        ([range(1; 4) | . as $g | (130 - ($g * 31)) as $y | "<line class=\"grid\" x1=\"14\" y1=\"\($y)\" x2=\"370\" y2=\"\($y)\" />"] | join("")),
        "<line class=\"axis\" x1=\"14\" y1=\"131\" x2=\"370\" y2=\"131\" />",
        ([range(0; $a_data|length) | . as $i | ($a_data[$i]) as $item |
          (20 + $i * 71) as $x |
          (if $item.count > 0 then (($item.count * 93 / $a_max) | round) else 0 end) as $bh |
          (if $bh < 3 and $item.count > 0 then 3 else $bh end) as $bh2 |
          "<rect x=\"\($x)\" y=\"\(131 - $bh2)\" width=\"52\" height=\"\($bh2)\" rx=\"5\" fill=\"\($item.color)\"><title>\($item.label|h): \($item.count)</title></rect>"
          + "<text class=\"val\" x=\"\($x + 26)\" y=\"\(125 - $bh2)\" text-anchor=\"middle\">\($item.count)</text>"
          + "<text class=\"cap\" x=\"\($x + 26)\" y=\"148\" text-anchor=\"middle\">\($item.label|h)</text>"
         ] | join("")),
        "<text class=\"cap\" x=\"14\" y=\"165\">newest</text>",
        "<text class=\"cap\" x=\"370\" y=\"165\" text-anchor=\"end\">oldest</text>",
        "</svg>",
        "</div>",
        # Chart 4: Closes by evidence type (tracked horizontal bars)
        "<div class=\"chart-card\" id=\"chart-evidence\">",
        "<h3>Closes by evidence type</h3>",
        "<svg viewBox=\"0 0 380 150\" width=\"100%\" height=\"150\" role=\"img\" aria-label=\"Closes by evidence type\">",
        "<title>Closes by evidence type</title>",
        ([range(0; $e_data|length) | . as $i | ($e_data[$i]) as $item | (8 + $i * 28) as $y |
          (if $item.count > 0 then (($item.count * 208 / $e_max) | round) else 0 end) as $bw |
          (if $bw < 4 and $item.count > 0 then 4 else $bw end) as $bw2 |
          "<text class=\"cap\" x=\"0\" y=\"\($y + 14)\">\($item.label|h)</text>"
          + "<rect class=\"track\" x=\"118\" y=\"\($y + 2)\" width=\"208\" height=\"16\" rx=\"8\" />"
          + "<rect x=\"118\" y=\"\($y + 2)\" width=\"\($bw2)\" height=\"16\" rx=\"8\" fill=\"\($item.color)\"><title>\($item.label|h): \($item.count)</title></rect>"
          + "<text class=\"val\" x=\"336\" y=\"\($y + 14)\">\($item.count)</text>"
         ] | join("")),
        "</svg>",
        "</div>",
        "</div>",
        "<h2 id=\"next\">What to do next</h2>",
        "<ol class=\"todo\">",
        (if ($close|length) > 0 then "<li><a href=\"#close\">Review \($close|length) close candidate(s) below.</a></li>" else empty end),
        (if ($decisions|length) > 0 then "<li><a href=\"#decisions\">Answer \($decisions|length) decision(s) below.</a></li>" else empty end),
        (if ($themes|length) > 0 then "<li><a href=\"#themes\">Review \($themes|length) spec-worthy theme proposal(s) below.</a></li>" else empty end),
        (if ($findings|length) > 0 then "<li><a href=\"#findings\">Review \($findings|length) process finding(s) below.</a></li>" else empty end),
        (if ($conf_defects|length) > 0 then "<li><a href=\"#conformance\">Resolve \($conf_defects|length) conformance defect(s) below.</a></li>" else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($themes|length) == 0 and ($findings|length) == 0
            and ($conf_defects|length) == 0 and ($unverified|length) == 0
         then "<li class=\"is-clean\">Nothing to do — backlog is clean this run.</li>" else empty end),
        "</ol>",
        "<details class=\"sect\" id=\"sec-close\"><summary><h2 id=\"close\">Close now <span class=\"pill\">\($close|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($close|length) == 0 then "<p class=\"empty\">None this run.</p>"
         else
           "<div class=\"searchbar\"><input type=\"search\" id=\"q-close\" placeholder=\"Filter close candidates…\" aria-label=\"Filter close candidates\" onkeyup=\"groomFilterTable(&#39;q-close&#39;, &#39;table-close&#39;)\"></div>"
           + "<div class=\"table-wrap\"><table id=\"table-close\"><thead><tr>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 0)\">#</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 1)\">Title</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 2)\">Verdict</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 3)\">Priority</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 4)\">Group</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 5)\">Status</th>"
           + "<th class=\"sortable\" onclick=\"groomSortTable(&#39;table-close&#39;, 6)\">Reason / Evidence</th>"
           + "</tr></thead><tbody>"
           + ([$close[] |
               "<tr><td><a class=\"inum\" href=\"https://github.com/\($repo|h)/issues/\(.number)\">#\(.number)</a></td>"
               + "<td class=\"ititle\">\(.title // "(title unavailable)"|h)</td>"
               + "<td>\(.verdict | vbadge($titles))</td>"
               + "<td>\(pbadge)</td>"
               + "<td><span class=\"chip\">\(.group|h)</span></td>"
               + "<td><span class=\"status\(if (.status // "PENDING") == "PENDING" then "" else " status-done" end)\">\(.status // "PENDING"|h)</span></td>"
               + "<td>\(.reason|h)" + (if (.evidence // "") != "" then "<br><small class=\"cap\"><strong>Evidence:</strong> \(.evidence|h)</small>" else "" end) + "</td></tr>"] | join(""))
           + "</tbody></table></div>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-milestones\"><summary><h2 id=\"milestones\">Milestones <span class=\"pill\">\(if ($milestone_proposals|length) > 0 then ($milestone_proposals|length) else ($milestones|length) end)</span><span class=\"chev\"></span></h2></summary>",
        (if ($milestone_proposals|length) > 0 then
           "<ul class=\"plain\">" + ([$milestone_proposals[] |
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
             + (if $m then
                  "<div class=\"stat-meter\" style=\"--rail: var(--ok)\"><i style=\"width:\($m_closed | pct($m_open + $m_closed))%\"></i></div>"
                else "" end)
             + (if (($p.issues // [])|length > 0)
                then "<div class=\"meta-row\">" + (($p.issues // []) | map("<span class=\"chip\">" + ititle_h($titles; .) + "</span>") | join("")) + "</div>"
                else "" end)
             + (if $p.reason then " — \($p.reason|h)" else "" end)
             + "</li>"] | join("")) + "</ul>"
         elif ($milestones|length) == 0 then "<p class=\"empty\">No milestone proposals this run.</p>"
         else
           "<ul class=\"plain\">" + ([$milestones[] |
             . as $m |
             ([$rows[] | select(.milestone == $m.title and .status != "DONE")] | sort_by(- (.age_days // 0)) | first) as $oldest |
             ([$rows[] | select(.milestone == $m.title and .status == "DONE" and (.verdict | startswith("CLOSE-")))] | length) as $closed_here |
             ((($m.open_issues // 0) - $closed_here) | if . < 0 then 0 else . end) as $m_open |
             (($m.closed_issues // 0) + $closed_here) as $m_closed |
             "<li>#\($m.number) <strong>\($m.title|h)</strong> <span class=\"badge\">\($m.state|h)</span> — \($m_open) open, \($m_closed) closed"
             + "<div class=\"stat-meter\" style=\"--rail: var(--ok)\"><i style=\"width:\($m_closed | pct($m_open + $m_closed))%\"></i></div>"
             + (if $oldest then "<div class=\"meta-row\"><span class=\"chip\">health: open: \($m_open), closed: \($m_closed), oldest open issue: " + ititle_h($titles; $oldest.number) + " (\($oldest.age_days // 0) days old)</span></div>" else "<div class=\"meta-row\"><span class=\"chip\">health: open: \($m_open), closed: \($m_closed), no open issues</span></div>" end)
             + "</li>"] | join("")) + "</ul>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-parents\"><summary><h2 id=\"parents\">Parent issues <span class=\"pill\">\($parents|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($parents|length) == 0 then "<p class=\"empty\">No parent-tree proposals this run.</p>"
         else "<ul class=\"plain\">" + ([$parents[] |
             "<li>\(if .parent then ("<a class=\"inum\" href=\"https://github.com/" + ($repo|h) + "/issues/" + (.parent|tostring) + "\">#" + (.parent|tostring) + "</a> <strong>" + ((if (.title // "") != "" then .title else $titles[(.parent|tostring)] end) // "(title unavailable)" | h) + "</strong>") else "<span class=\"badge\">new</span> <strong>\(.title|h)</strong>" end)"
             + (if (.children // [])|length > 0
                then "<div class=\"meta-row\">" + ((.children // []) | map("<span class=\"chip\">" + ititle_h($titles; .) + "</span>") | join("")) + "</div>"
                else "" end)
             + "</li>"] | join("")) + "</ul>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-themes\"><summary><h2 id=\"themes\">Spec-worthy themes <span class=\"pill\">\($themes|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($themes|length) == 0 then "<p class=\"empty\">No spec-worthy theme proposals this run.</p>"
         else ([$themes[] |
           "<div class=\"card theme-card\">"
           + "<h3>\(.title|h) <span class=\"badge badge-v-decision\">\(.recommended_vehicle|h)</span></h3>"
           + "<p><strong>Reason:</strong> \(.reason|h)</p>"
           + "<ul class=\"chip-list\">"
           + ([(.issues // [])[] | "<li>" + ilink_h($titles; $repo; .) + "</li>"] | join(""))
           + "</ul>"
           + "<div class=\"callout callout-theme\"><p class=\"callout-response\"><strong>How to respond:</strong> Agree to draft spec via \(.recommended_vehicle|h), or decline to keep as individual issues.</p></div>"
           + "</div>"
         ] | join(""))
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-decisions\"><summary><h2 id=\"decisions\">Decisions <span class=\"pill\">\($decisions|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($decisions|length) == 0 then "<p class=\"empty\">None this run.</p>"
         else
           (if ($top_five|length) > 0 then
              "<h3>Top five</h3><div class=\"decisions\">"
              + ([range(0; $top_five|length) | . as $i | ($top_five[$i]) as $dec |
                 ($dec | pr_label) as $pr |
                 "<div class=\"decision\"><div class=\"rank\">\($i + 1)</div><div>"
                 + "<div class=\"decision-head\">" + ilink_h($titles; $repo; $dec.number) + ($dec | pbadge) + "</div>"
                 + "<p class=\"decision-q\">\($dec.question // ""|h)</p>"
                 + "<div class=\"callout callout-decision\">"
                 + "<div class=\"callout-title\">Recommendation</div>"
                 + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                 + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                 + "</div>"
                 + "<div class=\"meta-row\"><span class=\"chip\">Why ranked in top five: \($pr) priority, blocks \($dec.blocking_count // $dec.blocked_by_count // 0) downstream issue(s), \($dec.age_days // 0) days old.</span><span class=\"chip\">Status: \($dec.status // "PENDING"|h)</span></div>"
                 + "</div></div>"] | join(""))
              + "</div>"
            else "" end)
           + (if ($next_ten|length) > 0 then
              "<h3>Next ten</h3><div class=\"decisions\">"
              + ([range(0; $next_ten|length) | . as $i | ($next_ten[$i]) as $dec |
                 "<div class=\"decision\"><div class=\"rank plain\">\($i + 6)</div><div>"
                 + "<div class=\"decision-head\">" + ilink_h($titles; $repo; $dec.number) + ($dec | pbadge) + "</div>"
                 + "<p class=\"decision-q\">\($dec.question // ""|h)</p>"
                 + "<div class=\"callout callout-decision\">"
                 + "<div class=\"callout-title\">Recommendation</div>"
                 + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                 + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                 + "</div>"
                 + "<div class=\"meta-row\"><span class=\"chip\">Status: \($dec.status // "PENDING"|h)</span></div>"
                 + "</div></div>"] | join(""))
              + "</div>"
            else "" end)
           + (if ($remainder|length) > 0 then
              "<h3>Remainder by area</h3>"
              + ([$remainder | group_by(.group) | .[] |
                 "<h4>\(.[0].group|h) <span class=\"pill\">\(length)</span></h4><div class=\"decisions\">"
                 + ([.[] |
                    . as $dec |
                    "<div class=\"decision\"><div class=\"rank plain\">•</div><div>"
                    + "<div class=\"decision-head\">" + ilink_h($titles; $repo; $dec.number) + ($dec | pbadge) + "</div>"
                    + "<p class=\"decision-q\">\($dec.question // ""|h)</p>"
                    + "<div class=\"callout callout-decision\">"
                    + "<div class=\"callout-title\">Recommendation</div>"
                    + "<p class=\"callout-body\">\($dec.recommendation // $dec.reason | h)</p>"
                    + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to accept recommendation, &quot;decline&quot; to reject, or specify an alternative.</p>"
                    + "</div>"
                    + "<div class=\"meta-row\"><span class=\"chip\">Status: \($dec.status // "PENDING"|h)</span></div>"
                    + "</div></div>"] | join(""))
                 + "</div>"] | join(""))
            else "" end)
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-completed\"><summary><h2 id=\"completed\">Completed this run <span class=\"pill\">\(($close_done|length) + ($decisions_done|length))</span><span class=\"chev\"></span></h2></summary>",
        (if (($close_done|length) + ($decisions_done|length)) == 0 then "<p class=\"empty\">None this run.</p>"
         else "<ul class=\"plain\">"
           + ([$close_done[] | "<li class=\"done\">" + ilink_h($titles; $repo; .number) + " <span class=\"badge badge-v-close\">close — status: \(.status|h)</span></li>"] | join(""))
           + ([$decisions_done[] | "<li class=\"done\">" + ilink_h($titles; $repo; .number) + " <span class=\"badge badge-v-decision\">decision — status: \(.status|h)</span></li>"] | join(""))
           + "</ul>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-findings\"><summary><h2 id=\"findings\">Process findings <span class=\"pill\">\($findings|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($findings|length) == 0 then "<p class=\"empty\">None recorded this run.</p>"
         else
           "<div class=\"table-wrap\"><table><thead><tr><th>Finding</th><th>Recommended action</th></tr></thead><tbody>"
           + ([$findings[] |
              (if type == "object" then .finding else . end) as $f_text |
              (if type == "object" then .recommended_action else "Review finding" end) as $f_act |
              "<tr><td>\($f_text|h)</td><td>"
              + "<div class=\"callout callout-finding\">"
              + "<p class=\"callout-body\">\($f_act|h)</p>"
              + "<p class=\"callout-response\"><strong>How to respond:</strong> Reply &quot;agree&quot; to apply remediation, or &quot;decline&quot;.</p>"
              + "</div>"
              + "</td></tr>"] | join(""))
           + "</tbody></table></div>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-conformance\"><summary><h2 id=\"conformance\">Conformance <span class=\"pill\">\($conf_defects|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($conf_defects|length) == 0 then "<p class=\"empty\">None recorded this run.</p>"
         else
           "<div class=\"table-wrap\"><table><thead><tr><th>#</th><th>Title</th><th>Kind</th><th>Defect</th><th>Proposed fix</th></tr></thead><tbody>"
           + ([$conf_defects[] |
              "<tr><td><a class=\"inum\" href=\"https://github.com/\($repo|h)/issues/\(.number)\">#\(.number)</a></td><td class=\"ititle\">\(.title // ""|h)</td><td><span class=\"chip\">\(.kind // ""|h)</span></td><td>\(.defect // ""|h)</td><td><span class=\"badge badge-v-decision\">\(.fix // ""|h)</span></td></tr>"
             ] | join(""))
           + "</tbody></table></div>"
         end),
        "</details>",
        "<details class=\"sect\" id=\"sec-bots\"><summary><h2 id=\"bots\">Bot-owned issues (excluded from retitle/close/relabel) <span class=\"pill\">\($bots|length)</span><span class=\"chev\"></span></h2></summary>",
        (if ($bots|length) == 0 then "<p class=\"empty\">None this run.</p>"
         else "<ul class=\"chip-list\">" + ([$bots[] | "<li>" + ilink_h($titles; $repo; .number) + "</li>"] | join("")) + "</ul>"
         end),
        # Close Bot-owned before opening this one: emitted inside it, a
        # partial audit hid its own Unverified list inside an unrelated
        # collapsed section (Codex on PR #1101).
        "</details>",
        (if ($unverified|length) == 0 then empty else
          "<details class=\"sect\" id=\"sec-unverified\"><summary><h2 id=\"unverified\">Unverified <span class=\"pill\">\($unverified|length)</span><span class=\"chev\"></span></h2></summary>",
          "<p>Open issues with no verdict row this run (join --allow-missing):</p>",
          "<ul class=\"chip-list\">" + ([$unverified[] | "<li>" + ilink_h($titles; $repo; .) + "</li>"] | join("")) + "</ul>",
          "</details>"
         end),
        "<details class=\"sect\" id=\"sec-every-issue\"><summary><h2 id=\"every-issue\">Every issue <span class=\"pill\">\($audited)</span><span class=\"chev\"></span></h2></summary>",
        "<div class=\"searchbar\"><input type=\"search\" id=\"q\" placeholder=\"Filter by number, title, verdict, group…\" aria-label=\"Filter every issue\" onkeyup=\"groomFilter()\"></div>",
        "<div class=\"table-wrap\"><table id=\"t\"><thead><tr>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 0)\">#</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 1)\">Title</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 2)\">Verdict</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 3)\">Priority</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 4)\">Group</th>",
        "<th class=\"sortable\" onclick=\"groomSortTable(&#39;t&#39;, 5)\">Status</th>",
        "</tr></thead><tbody>",
        ([$rows[] |
          "<tr><td><a class=\"inum\" href=\"https://github.com/\($repo|h)/issues/\(.number)\">#\(.number)</a></td>"
          + "<td class=\"ititle\">\(.title // ""|h)</td>"
          + "<td><span class=\"badge badge-\(.verdict | vclass)\">\(.verdict|h)</span></td>"
          + "<td>\(pbadge)</td>"
          + "<td><span class=\"chip\">\(.group|h)</span></td>"
          + "<td><span class=\"status\(if (.status // "PENDING") == "PENDING" then "" else " status-done" end)\">\(.status // "PENDING"|h)</span></td></tr>"] | join("")),
        "</tbody></table></div>",
        "</details>",
        "</main>",
        "<footer>Rendered by the groom skill — read-only audit. Every write goes through the skill scripts behind --execute.</footer>",
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
        "function groomReveal(hash) {",
        "  if (!hash || hash.charAt(0) !== \"#\") return;",
        "  var el = document.getElementById(hash.slice(1));",
        "  if (!el || !el.closest) return;",
        "  var d = el.closest(\"details\");",
        "  while (d) {",
        "    d.open = true;",
        "    d = d.parentElement ? d.parentElement.closest(\"details\") : null;",
        "  }",
        "  el.scrollIntoView();",
        "}",
        "window.addEventListener(\"hashchange\", function () { groomReveal(location.hash); });",
        "var groomPrintOpened = [];",
        "window.addEventListener(\"beforeprint\", function () {",
        "  groomPrintOpened = [];",
        "  var d = document.querySelectorAll(\"details.sect\");",
        "  for (var i = 0; i < d.length; i++) {",
        "    if (!d[i].open) { groomPrintOpened.push(d[i]); d[i].open = true; }",
        "  }",
        "});",
        "window.addEventListener(\"afterprint\", function () {",
        "  for (var i = 0; i < groomPrintOpened.length; i++) { groomPrintOpened[i].open = false; }",
        "  groomPrintOpened = [];",
        "});",
        "document.addEventListener(\"DOMContentLoaded\", function () { groomReveal(location.hash); });",
        "document.addEventListener(\"click\", function (e) {",
        "  var t = e.target;",
        "  if (!t || !t.closest) return;",
        "  var a = t.closest(\"a\");",
        "  if (a) groomReveal(a.getAttribute(\"href\"));",
        "});",
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
