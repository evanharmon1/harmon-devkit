#!/usr/bin/env bash
# Run shellcheck/shfmt over tracked shell files without losing paths that
# contain spaces. harmon-devkit keeps intentionally incomplete snippets out of
# operational lint/format passes while still validating executable templates.
set -euo pipefail

mode="${1:-}"
[ "$#" -gt 0 ] && shift

exclude_snippets=false
if [ "${1:-}" = "--exclude-snippets" ]; then
    exclude_snippets=true
    shift
fi

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    pathspecs=('*.sh' '*.bash')
    if $exclude_snippets; then
        pathspecs+=(':(exclude)snippets/**')
    fi
    while IFS= read -r -d '' file; do
        files+=("$file")
    done < <(git ls-files -z -- "${pathspecs[@]}")
fi

[ "${#files[@]}" -gt 0 ] || exit 0

case "$mode" in
check)
    shellcheck --severity=error "${files[@]}"
    shfmt -d "${files[@]}"
    ;;
format)
    shfmt -w "${files[@]}"
    ;;
*)
    echo "Usage: $0 <check|format> [--exclude-snippets] [file ...]" >&2
    exit 2
    ;;
esac
