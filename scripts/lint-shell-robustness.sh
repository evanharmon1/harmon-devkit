#!/usr/bin/env bash
# lint-shell-robustness.sh — guard the two shell idioms in this repo whose
# EXIT STATUS LIES, both of which have already cost real gate time (#689).
#
# 1. `PRODUCER | grep -q PATTERN` under `set -o pipefail`.
#
#    `grep -q` exits the moment it matches. The producer is usually still
#    writing, so it takes SIGPIPE and dies 141; `pipefail` then reports the
#    whole pipeline as FAILED even though grep MATCHED. It is a race on how
#    much is still in flight when grep leaves, so it is load-sensitive and
#    reproduces best under a loaded gate: measured here at 0/100 false
#    negatives for a 150-byte payload, 1/100 at 1.5 kB, 94/100 at 84 kB and
#    200/200 at 349 kB. Seen in production code as well as tests — the triage
#    skill's `axes_active()` silently dropped a classification axis this way.
#
#    Fixed shape: take the producer out of the pipeline, so only grep's own
#    verdict is returned.
#        grep -qF "$needle" <<<"$haystack"          # a string
#        grep -q PATTERN < <(some-command --args)   # a command
#
#    One caveat on the second form: a process substitution DISCARDS the
#    producer's exit status, so a command that emits a matching line and then
#    fails reads as a clean match. That is the same answer `pipefail` gave
#    whenever the producer wrote nothing, so it is no worse for a plain
#    "does the output contain X" question — but where successful completion
#    is itself part of the invariant (a safety gate deciding whether to
#    delete something), capture first and let the failure surface:
#        records="$(git worktree list --porcelain)" &&
#            grep -qxF "worktree $tree" <<<"$records"
#
# 2. A test-suite reporter helper (`ok`, `bad`, `pass`, `fail`, …) that does
#    not end in `return 0`.
#
#    Assertions are written `check && ok "..." || bad "..."`, which puts the
#    reporter's own status inside the branch: if its `echo` ever fails — a
#    transient write error on the grouped-output pipe `task` runs suites
#    under — a PASSING assertion is reported as a failure. Under `set -e` the
#    same failure can instead abort the suite outright.
#
#    Fixed shape:
#        ok() {
#            pass=$((pass + 1))
#            echo "  ✓ $*" || true
#            return 0
#        }
#
# Scope: tracked `*.sh` under scripts/ and ai/skills/ for check 1; tracked
# scripts/test-*.sh for check 2. Here-document bodies are skipped by both:
# they hold fixture and stub payloads, including deliberately frozen snapshots
# of superseded code that must not be "fixed".
#
# Usage: ./scripts/lint-shell-robustness.sh [file ...]
#   With no arguments, checks every tracked file in scope.
set -euo pipefail

# Resolve the scanner beside this script rather than through the caller's cwd,
# so an explicit file list can be checked from anywhere (the unit test drives
# fixtures in a temp dir).
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scanner="${here}/lib/shell-robustness.awk"
[ -f "${scanner}" ] || {
    echo "lint-shell-robustness: missing scanner ${scanner}" >&2
    exit 1
}

files=()
explicit=0
if [ $# -gt 0 ]; then
    explicit=1
    files=("$@")
else
    cd "$(git rev-parse --show-toplevel)"
    # git pathspec globs match across `/`, so this reaches nested skill assets.
    while IFS= read -r f; do
        files+=("$f")
    done < <(git ls-files -- 'scripts/*.sh' 'ai/skills/*.sh' | sort)
fi

[ ${#files[@]} -gt 0 ] || {
    echo "lint-shell-robustness: no shell scripts in scope" >&2
    exit 1
}

findings="$(mktemp)"
trap 'rm -f "${findings}"' EXIT

for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
        # A path the caller NAMED and that is not there is an error, not a
        # clean file: this guard's whole job is to not report "clean" over
        # something it never looked at. A tracked path that has since been
        # deleted is the ordinary `git ls-files` case and is simply skipped.
        if [ "$explicit" -eq 1 ]; then
            echo "lint-shell-robustness: no such file: $f" >&2
            exit 1
        fi
        continue
    fi
    awk -v FILE="$f" -f "${scanner}" "$f"
done >"$findings"

if [ -s "$findings" ]; then
    cat "$findings" >&2
    echo >&2
    echo "lint-shell-robustness: $(wc -l <"${findings}" | tr -d " ") finding(s)." >&2
    echo "  See the header of scripts/lint-shell-robustness.sh for the fixed shapes." >&2
    exit 1
fi

echo "lint-shell-robustness: ${#files[@]} file(s) clean"
