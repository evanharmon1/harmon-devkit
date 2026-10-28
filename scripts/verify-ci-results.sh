#!/usr/bin/env bash
# Verify that every named CI leaf has the one result the caller expects.
#
# Usage:
#   EXPECTED_RESULT=success ./scripts/verify-ci-results.sh check=success security=success
#
# Fork aggregates deliberately do not invoke this repository-controlled file;
# they perform the equivalent skipped-only check inline in the trusted workflow.
set -euo pipefail

expected="${EXPECTED_RESULT:-success}"
case "$expected" in
success | skipped) ;;
*)
    echo "Invalid expected CI result: ${expected}" >&2
    exit 2
    ;;
esac

if [ "$#" -eq 0 ]; then
    echo "At least one name=result pair is required." >&2
    exit 2
fi

# Only the workflow identifies skip-eligible jobs; check/repo-guards/security
# remain ordinary required pairs. Classification must itself have succeeded.
docs_skip=false
if [ "${DOCS_ONLY:-}" = true ] && [ "${CHANGES_RESULT:-}" = success ] &&
    [ "${CI_EVENT_NAME:-}" = pull_request ]; then
    docs_skip=true
fi

failed=0
for pair in "$@"; do
    case "$pair" in
    *=*) ;;
    *)
        echo "Invalid CI result argument (expected name=result): ${pair}" >&2
        failed=1
        continue
        ;;
    esac

    name="${pair%%=*}"
    result="${pair#*=}"
    if [ -z "$name" ] || [ -z "$result" ]; then
        echo "Invalid CI result argument (name and result are required): ${pair}" >&2
        failed=1
    elif [ "$expected" = success ] && [ "$result" = skipped ] &&
        [ "$docs_skip" = true ] && [[ " ${DOCS_ONLY_JOBS:-} " == *" $name "* ]]; then
        echo "Job ${name} deliberately skipped: docs-only"
    elif [ "$result" != "$expected" ]; then
        echo "Job ${name} result: ${result} (expected ${expected})" >&2
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    echo "One or more required jobs did not have the expected result." >&2
    exit 1
fi

echo "All required jobs satisfied their expected result (${expected}); deliberate docs-only skips are listed above."
