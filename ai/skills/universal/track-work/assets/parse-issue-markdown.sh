#!/usr/bin/env bash
# parse-issue-markdown.sh — expose one shared rendered-Markdown model to the
# issue-authoring checks. The same AWK program enumerates criteria for the
# write-capable ticker, so structure validation cannot drift into a weaker
# parallel parser.
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
awk -v mode="$mode" -f "$asset_dir/parse-issue-markdown.awk" "$2" || {
    echo "parse-issue-markdown: could not parse draft" >&2
    exit 2
}
