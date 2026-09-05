#!/usr/bin/env bash
# gh-ro.sh — a structurally read-only front door for `gh api`.
#
# An allowed-tools entry can only pre-approve a command prefix, and the
# `gh api` prefix can mutate — the same prefix that lists comments posts them.
# This wrapper is the prefix that cannot: it vets every argument against a
# small allowlist, refuses anything that could turn the request into a write,
# and then execs `gh api` with `--method GET` pinned. Fail-closed by
# construction — an argument this script does not recognise is refused, never
# forwarded.
#
# Permitted:
#   - exactly one REST endpoint (positional; query strings like ?per_page=100
#     ride along in the endpoint)
#   - --paginate, --slurp
#   - --jq EXPR / -q EXPR / --jq=EXPR (client-side output shaping)
#   - -X GET / --method GET / --method=GET — the default, restated; any other
#     method is refused
#
# Refused, deliberately:
#   - -f/--raw-field, -F/--field, --input: request fields and bodies. Fields
#     are not only payload — their presence flips gh's default method to POST.
#   - the `graphql` endpoint. GraphQL rides POST and can carry mutations, and
#     proving a query harmless means parsing GraphQL. The choice here is to
#     EXCLUDE it rather than restrict it: the GraphQL reads the shepherd skill
#     needs (review-thread resolution) live inside readiness-gate.sh, so the
#     wrapper stays a trivially auditable GET gate. Raw `gh api graphql`
#     remains available and prompts.
#   - --hostname, --header/-H, --cache, --include/-i, --preview/-p,
#     --template/-t, --verbose, --silent, and every other flag: not needed by
#     any call the skill prescribes, and a smaller surface is easier to prove
#     read-only. Widen the allowlist only with a written reason.
#   - attached short-flag values (-q.login, -XGET): vetting them safely means
#     reimplementing gh's exact flag parsing; the detached spellings cost
#     nothing.
#
# Exit codes: 2 for a refusal or usage error; otherwise `gh api`'s own.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  gh-ro.sh ENDPOINT [--paginate] [--slurp] [--jq EXPR] [-X GET]

A read-only wrapper for `gh api`: vets the arguments, refuses anything that
could write (non-GET methods, field/body flags, the graphql endpoint —
GraphQL rides POST and can carry mutations, so its reads live inside
readiness-gate.sh instead), and execs `gh api --method GET` with the vetted
arguments. Unrecognised flags are refused, not forwarded.
EOF
    exit 2
}

refuse() {
    printf 'gh-ro: refused: %s\n' "$*" >&2
    exit 2
}

command -v gh >/dev/null 2>&1 || refuse "gh is required"

[ "$#" -gt 0 ] || usage

# POSIX-portable vetting without arrays: consume the original arguments from
# the front of "$@" while appending vetted pass-through flags to the back,
# for exactly the original count of iterations.
endpoint=
original_count=$#
while [ "$original_count" -gt 0 ]; do
    argument=$1
    shift
    original_count=$((original_count - 1))
    case "$argument" in
    --paginate | --slurp)
        set -- "$@" "$argument"
        ;;
    --jq | -q)
        [ "$original_count" -ge 1 ] || refuse "$argument requires a value"
        set -- "$@" --jq "$1"
        shift
        original_count=$((original_count - 1))
        ;;
    --jq=*)
        set -- "$@" "$argument"
        ;;
    -X | --method)
        [ "$original_count" -ge 1 ] || refuse "$argument requires a value"
        [ "$1" = "GET" ] ||
            refuse "method $1 — only GET is permitted"
        # Dropped, not forwarded: the exec below pins --method GET itself.
        shift
        original_count=$((original_count - 1))
        ;;
    --method=*)
        [ "${argument#--method=}" = "GET" ] ||
            refuse "method ${argument#--method=} — only GET is permitted"
        ;;
    -f | --raw-field | -F | --field | --input)
        refuse "$argument carries request fields or a body (and fields flip gh api's default method to POST)"
        ;;
    -*)
        refuse "unrecognised flag $argument — the allowlist is deliberately small; use raw gh api (it prompts) for anything beyond a plain GET"
        ;;
    "")
        refuse "empty argument"
        ;;
    *)
        [ -z "$endpoint" ] ||
            refuse "more than one endpoint ($endpoint and $argument)"
        endpoint=$argument
        ;;
    esac
done

[ -n "$endpoint" ] || refuse "an endpoint is required"

# Normalise leading slashes and case purely for the graphql comparison; the
# endpoint itself is forwarded untouched.
trimmed=$endpoint
while [ "${trimmed#/}" != "$trimmed" ]; do
    trimmed=${trimmed#/}
done
lowered=$(printf '%s' "$trimmed" | tr '[:upper:]' '[:lower:]')
case "$lowered" in
graphql | graphql/* | graphql\?*)
    refuse "the graphql endpoint — GraphQL rides POST and can carry mutations; readiness-gate.sh owns the skill's GraphQL reads"
    ;;
esac
# gh api honors an absolute http(s) URL verbatim, bypassing the API host —
# which would let a pre-approved wrapper GET internal or metadata endpoints.
# GET is only side-effect-free by convention on GitHub's own REST surface,
# so only relative paths resolved against the authenticated API host pass.
case "$endpoint" in
*://*)
    refuse "an absolute URL — only relative GitHub REST paths, resolved against the authenticated API host, are permitted"
    ;;
esac

exec gh api --method GET "$@" "$endpoint"
