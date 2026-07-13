#!/usr/bin/env bash
# A small, safe Bash script starter. Replace the description and main body.
set -Eeuo pipefail

usage() {
    cat <<'USAGE'
Usage: script-name [-h] [-v] [-f] -p VALUE ARG [ARG...]

Describe what the script does.

Options:
  -h, --help         Show this help and exit
  -v, --verbose      Enable shell tracing
  -f, --flag         Example boolean flag
  -p, --param VALUE  Example required parameter
USAGE
}

cleanup() {
    trap - SIGINT SIGTERM ERR EXIT
    # Remove temporary resources here.
}

die() {
    local message="$1"
    local code="${2:-1}"
    printf 'error: %s\n' "$message" >&2
    exit "$code"
}

main() {
    local flag=false
    local param=""
    local -a args=()

    while [ "$#" -gt 0 ]; do
        case "$1" in
        -h | --help)
            usage
            return 0
            ;;
        -v | --verbose)
            set -x
            shift
            ;;
        -f | --flag)
            flag=true
            shift
            ;;
        -p | --param)
            [ "$#" -ge 2 ] || die "$1 requires a value"
            param="$2"
            shift 2
            ;;
        --)
            shift
            args+=("$@")
            break
            ;;
        -*) die "unknown option: $1" ;;
        *)
            args+=("$1")
            shift
            ;;
        esac
    done

    [ -n "$param" ] || die "missing required option: --param"
    [ "${#args[@]}" -gt 0 ] || die "at least one positional argument is required"

    printf 'flag=%s\n' "$flag"
    printf 'param=%s\n' "$param"
    printf 'arguments=%s\n' "${args[*]}"
}

trap cleanup SIGINT SIGTERM ERR EXIT
main "$@"
