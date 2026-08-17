#!/usr/bin/env bash
# parse-issue-markdown.sh — expose one shared Markdown model to the
# issue-authoring checks. The same AWK program enumerates criteria for the
# write-capable ticker, so structure validation cannot drift into a weaker
# parallel parser.
#
# Exit: 0 parsed, 2 usage or unreadable input, 3 the draft is outside the
# mechanized authoring profile (the parser prints one diagnostic per offending
# line on stderr). Callers map 3 to their own safe direction: a contract
# violation for the pre-create gate, a refusal to write for the ticker,
# indeterminate for a read-only guard.
set -euo pipefail

usage() {
    echo "Usage: $0 --structure|--evidence|--tasks|--criteria DRAFT_FILE" >&2
    exit 2
}

case "${1:-}" in
--structure | --evidence | --tasks | --criteria) ;;
*) usage ;;
esac
[ "$#" -eq 2 ] || usage
[ -f "$2" ] && [ -r "$2" ] || {
    echo "parse-issue-markdown: cannot read draft: $2" >&2
    exit 2
}

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
mode="${1#--}"
rc=0
awk -v mode="$mode" -f "$asset_dir/parse-issue-markdown.awk" "$2" || rc=$?
case "$rc" in
0) exit 0 ;;
3) exit 3 ;;
*)
    echo "parse-issue-markdown: could not parse draft" >&2
    exit 2
    ;;
esac
