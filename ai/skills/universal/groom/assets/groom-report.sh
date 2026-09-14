#!/usr/bin/env bash
# groom-report.sh — render the groom dispositions dataset (groom-verdicts.sh
# join output) into a self-contained HTML report and a Markdown summary.
# Read-only: writes only to the two output files named on its command line,
# never to GitHub. Deterministic — the same dataset renders byte-identical
# output (the generation timestamp is injectable via GROOM_NOW for tests), so
# the HTML can be republished to the same Artifact after every apply step
# (issue #1015).
#
# Section order (fixed, per the issue): Stats strip; What to do next; Close
# now (grouped by verdict, every entry showing number AND title); Milestones;
# Parent issues; Decisions (with a status column); Process findings;
# Bot-owned issues; Unverified (only when the dataset carries any —
# stats.unverified, from groom-verdicts.sh join --allow-missing); Every issue
# (full table with inline filter/search).
#
# Usage:
#   groom-report.sh render --dispositions PATH --out-html PATH --out-md PATH
#                           [--outcomes PATH]
#
# --outcomes PATH (optional) is a JSON Lines file of applied-write records
# written by groom-apply.sh/groom-decide.sh's own --outcomes flag:
#   {"issue":N,"op":"...","status":"DONE"|"DECIDED <date>","at":"<UTC>"}
# The LAST record for a given issue number overrides that row's `status`
# column — republishing the report after an apply step (SKILL.md Step 6)
# is otherwise a byte-identical re-render of the plan, forever showing
# PENDING no matter what was actually applied (finding 8).
#
# Exit: 0 = rendered, 2 = usage/read error.
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
    [ -r "$dispositions" ] || die "cannot read dispositions dataset: $dispositions"

    local now
    now="${GROOM_NOW:-$(date -u '+%Y-%m-%d %H:%M UTC')}"

    local outcomes_map="{}"
    if [ -n "$outcomes" ]; then
        [ -r "$outcomes" ] || die "cannot read outcomes file: $outcomes"
        outcomes_map="$(jq -s '
          reduce .[] as $o ({}; .[($o.issue|tostring)] = $o.status)
        ' "$outcomes")"
    fi

    jq -r --arg now "$now" --argjson outcomes_map "$outcomes_map" '
      # Markdown-safe: collapse embedded newlines (which would otherwise
      # split a table row or bullet across lines) and escape a literal "|"
      # (which would otherwise insert a phantom table-cell boundary) in any
      # free text sourced from an issue title, a subagent reason/question, or
      # a process finding.
      def mdesc: if . == null then "" else
        (. | tostring | gsub("\r\n|\r|\n"; " ") | gsub("\\|"; "\\|")) end;
      . as $d
      | ($d.dispositions // []
         | map(. + {status: ($outcomes_map[(.number|tostring)] // .status // "PENDING")})
        ) as $rows
      | ([$rows[] | select(.verdict | startswith("CLOSE-"))]) as $close
      | ([$rows[] | select(.verdict == "NEEDS-DECISION")]) as $decisions
      | ([$rows[] | select(.bot_owned == true)]) as $bots
      | ($d.stats // {}) as $stats
      | ($d.milestones // []) as $milestones
      | ($d.process_findings // []) as $findings
      | ($d.proposals.parents // []) as $parents
      | ($d.proposals.milestones // []) as $milestone_proposals
      | ($stats.unverified // []) as $unverified

      | "# Groom report — \($d.repo // "unknown")",
        "",
        "_Generated: \($now)_",
        "",
        "## Stats",
        "",
        "- Open issues: \($stats.open_total // 0)",
        "- Close candidates: \($stats.close_candidates // ($close|length))",
        "- Decisions needed: \($stats.decisions // ($decisions|length))",
        "- High priority: \($stats.high_priority // 0)",
        "",
        "## What to do next",
        "",
        (if ($close|length) > 0 then "1. Review \($close|length) close candidate(s) below." else empty end),
        (if ($decisions|length) > 0 then "1. Answer \($decisions|length) decision(s) below." else empty end),
        (if ($findings|length) > 0 then "1. Review \($findings|length) process finding(s) below." else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($findings|length) == 0
         then "Nothing to do — backlog is clean this run." else empty end),
        "",
        "## Close now",
        "",
        (if ($close|length) == 0 then "None this run."
         else ($close | group_by(.verdict) | .[] |
               "### \(.[0].verdict)",
               "",
               (.[] | "- #\(.number) — \(.title // "(title unavailable)" | mdesc) — \(.reason | mdesc)"),
               "")
         end),
        "## Milestones",
        "",
        (if ($milestone_proposals|length) > 0 then
           ($milestone_proposals[] |
            "- \(.action | mdesc) \(.title | mdesc)"
            + (if .new_title then " → \(.new_title | mdesc)" else "" end)
            + (if (.issues // [])|length > 0
               then " (" + ((.issues // []) | map("#\(.)") | join(", ")) + ")"
               else "" end))
         elif ($milestones|length) == 0 then "No milestone proposals this run."
         else ($milestones[] | "- #\(.number) \(.title | mdesc) (\(.state)) — \(.open_issues // 0) open, \(.closed_issues // 0) closed")
         end),
        "",
        "## Parent issues",
        "",
        (if ($parents|length) == 0 then "No parent-tree proposals this run."
         else ($parents[] |
               "- \(if .parent then "#\(.parent)" else "(new)" end) \(.title | mdesc)"
               + (if (.children // [])|length > 0
                  then ": " + ((.children // []) | map("#\(.)") | join(", "))
                  else "" end))
         end),
        "",
        "## Decisions",
        "",
        (if ($decisions|length) == 0 then "None this run."
         else ($decisions[] |
               "- #\(.number) — \(.title // "(title unavailable)" | mdesc) — \(.question // "" | mdesc) — recommendation: \(.reason | mdesc) — status: \(.status // "PENDING" | mdesc)")
         end),
        "",
        "## Process findings",
        "",
        (if ($findings|length) == 0 then "None recorded this run."
         else ($findings[] | "- \(. | mdesc)")
         end),
        "",
        "## Bot-owned issues (excluded from retitle/close/relabel)",
        "",
        (if ($bots|length) == 0 then "None this run."
         else ($bots[] | "- #\(.number) — \(.title // "(title unavailable)" | mdesc)")
         end),
        "",
        (if ($unverified|length) == 0 then empty else
          "## Unverified",
          "",
          "Open issues with no verdict row this run (join --allow-missing):",
          "",
          ($unverified[] | "- #\(.)"),
          ""
         end),
        "## Every issue",
        "",
        "| # | Title | Verdict | Priority | Group | Status |",
        "| --- | --- | --- | --- | --- | --- |",
        ($rows[] | "| #\(.number) | \(.title // "" | mdesc) | \(.verdict | mdesc) | \(.priority | mdesc) | \(.group | mdesc) | \(.status // "PENDING" | mdesc) |")
    ' "$dispositions" >"$out_md"

    jq -r --arg now "$now" --argjson outcomes_map "$outcomes_map" '
      def h: tostring
        | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")
        | gsub("\""; "&quot;");
      . as $d
      | ($d.dispositions // []
         | map(. + {status: ($outcomes_map[(.number|tostring)] // .status // "PENDING")})
        ) as $rows
      | ($d.repo // "unknown") as $repo
      | ([$rows[] | select(.verdict | startswith("CLOSE-"))]) as $close
      | ([$rows[] | select(.verdict == "NEEDS-DECISION")]) as $decisions
      | ([$rows[] | select(.bot_owned == true)]) as $bots
      | ($d.stats // {}) as $stats
      | ($d.milestones // []) as $milestones
      | ($d.process_findings // []) as $findings
      | ($d.proposals.parents // []) as $parents
      | ($d.proposals.milestones // []) as $milestone_proposals
      | ($stats.unverified // []) as $unverified
      | "<!doctype html><meta charset=\"utf-8\">",
        "<title>Groom report — \($repo|h)</title>",
        "<style>",
        "body{font:14px system-ui,sans-serif;margin:2rem;color:#1a1a1a;background:#fff}",
        "table{border-collapse:collapse;width:100%;margin:.5rem 0}",
        "th,td{border:1px solid #ddd;padding:.35rem .5rem;text-align:left;font-size:.9em}",
        "th{background:#f4f4f4;position:sticky;top:0}",
        "h1{font-size:1.3rem}h2{font-size:1.05rem;margin-top:2rem;border-bottom:1px solid #ddd}",
        ".stats span{display:inline-block;margin-right:1.5rem;font-weight:600}",
        "input[type=search]{padding:.3rem;width:100%;max-width:24rem;margin:.5rem 0}",
        "@media (prefers-color-scheme:dark){body{background:#111;color:#eee}th{background:#222}th,td{border-color:#444}}",
        "</style>",
        "<h1>Groom report — \($repo|h)</h1>",
        "<p><em>Generated: \($now|h)</em></p>",
        "<h2>Stats</h2>",
        "<p class=stats>",
        "<span>Open: \($stats.open_total // 0)</span>",
        "<span>Close candidates: \($stats.close_candidates // ($close|length))</span>",
        "<span>Decisions: \($stats.decisions // ($decisions|length))</span>",
        "<span>High priority: \($stats.high_priority // 0)</span>",
        "</p>",
        "<h2>What to do next</h2>",
        "<ol>",
        (if ($close|length) > 0 then "<li>Review \($close|length) close candidate(s) below.</li>" else empty end),
        (if ($decisions|length) > 0 then "<li>Answer \($decisions|length) decision(s) below.</li>" else empty end),
        (if ($findings|length) > 0 then "<li>Review \($findings|length) process finding(s) below.</li>" else empty end),
        (if ($close|length) == 0 and ($decisions|length) == 0 and ($findings|length) == 0
         then "<li>Nothing to do — backlog is clean this run.</li>" else empty end),
        "</ol>",
        "<h2>Close now</h2>",
        (if ($close|length) == 0 then "<p>None this run.</p>"
         else ([$close | group_by(.verdict) | .[] |
                "<h3>\(.[0].verdict|h)</h3><ul>"
                + ([.[] | "<li>#\(.number) — \(.title // "(title unavailable)"|h) — \(.reason|h)</li>"] | join(""))
                + "</ul>"] | join(""))
         end),
        "<h2>Milestones</h2>",
        (if ($milestone_proposals|length) > 0 then
           "<ul>" + ([$milestone_proposals[] |
             "<li>\(.action|h) \(.title|h)"
             + (if .new_title then " → \(.new_title|h)" else "" end)
             + (if (.issues // [])|length > 0
                then " (" + ((.issues // []) | map("#\(.)") | join(", ")) + ")"
                else "" end)
             + "</li>"] | join("")) + "</ul>"
         elif ($milestones|length) == 0 then "<p>No milestone proposals this run.</p>"
         else "<ul>" + ([$milestones[] | "<li>#\(.number) \(.title|h) (\(.state|h)) — \(.open_issues // 0) open, \(.closed_issues // 0) closed</li>"] | join("")) + "</ul>"
         end),
        "<h2>Parent issues</h2>",
        (if ($parents|length) == 0 then "<p>No parent-tree proposals this run.</p>"
         else "<ul>" + ([$parents[] |
             "<li>\(if .parent then "#\(.parent)" else "(new)" end) \(.title|h)"
             + (if (.children // [])|length > 0
                then ": " + ((.children // []) | map("#\(.)") | join(", "))
                else "" end)
             + "</li>"] | join("")) + "</ul>"
         end),
        "<h2>Decisions</h2>",
        (if ($decisions|length) == 0 then "<p>None this run.</p>"
         else "<ul>" + ([$decisions[] | "<li>#\(.number) — \(.title // "(title unavailable)"|h) — \(.question // ""|h) — recommendation: \(.reason|h) — status: \(.status // "PENDING"|h)</li>"] | join("")) + "</ul>"
         end),
        "<h2>Process findings</h2>",
        (if ($findings|length) == 0 then "<p>None recorded this run.</p>"
         else "<ul>" + ([$findings[] | "<li>\(.|h)</li>"] | join("")) + "</ul>"
         end),
        "<h2>Bot-owned issues (excluded from retitle/close/relabel)</h2>",
        (if ($bots|length) == 0 then "<p>None this run.</p>"
         else "<ul>" + ([$bots[] | "<li>#\(.number) — \(.title // "(title unavailable)"|h)</li>"] | join("")) + "</ul>"
         end),
        (if ($unverified|length) == 0 then empty else
          "<h2>Unverified</h2>",
          "<p>Open issues with no verdict row this run (join --allow-missing):</p>",
          "<ul>" + ([$unverified[] | "<li>#\(.)</li>"] | join("")) + "</ul>"
         end),
        "<h2>Every issue</h2>",
        "<input type=search id=q placeholder=\"Filter by number, title, verdict, group…\" onkeyup=\"groomFilter()\">",
        "<table id=t><thead><tr><th>#</th><th>Title</th><th>Verdict</th><th>Priority</th><th>Group</th><th>Status</th></tr></thead><tbody>",
        ([$rows[] | "<tr><td>#\(.number)</td><td>\(.title // ""|h)</td><td>\(.verdict|h)</td><td>\(.priority|h)</td><td>\(.group|h)</td><td>\(.status // "PENDING"|h)</td></tr>"] | join("")),
        "</tbody></table>",
        "<script>",
        "function groomFilter(){",
        "var q=document.getElementById(\"q\").value.toLowerCase();",
        "var rows=document.querySelectorAll(\"#t tbody tr\");",
        "for(var i=0;i<rows.length;i++){",
        "var t=rows[i].textContent.toLowerCase();",
        "rows[i].hidden = q.length>0 && t.indexOf(q)===-1;",
        "}}",
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
