#!/usr/bin/env bash
# merge-base-policy.sh — decide which governing-policy argument a trusted
# caller passes to a merge-base policy reader it runs directly (harmon-devkit#1345).
#
# Usage: merge-base-policy.sh <merge-base> <merge-base-reader> <out-file> <branch-policy>
#
# <branch-policy> is the path the caller passes the reader as --policy (the
# branch's .devflow.toml). Run from inside the repository. Prints exactly one
# word on stdout:
#   present — the merge base has .devflow.toml; its bytes are now in <out-file>.
#             Pass:  --merge-base-policy <out-file>
#   absent  — the merge base has no .devflow.toml but the branch adds one, and
#             <merge-base-reader> supports the flag.
#             Pass:  --merge-base-policy-absent
#   none    — neither the merge base nor the branch has a policy.
#             Pass neither flag: the reader's no-policy fallback governs, and
#             it refuses --merge-base-policy-absent without a --policy file.
#
# Exit status: 0 with one of the three words; 1 when the answer is "absent"
# but the reader predates --merge-base-policy-absent (stop: an older reader
# that accepts any option would ignore the flag and let the branch policy
# govern); 2 when the answer is indeterminate or the usage is wrong. Never
# read a non-zero status, or empty output, as "absent" or "none".
#
# Absence is decided from a checked tree lookup, never from a failed
# `git show`: `git ls-tree` exits non-zero when the lookup itself fails and
# prints nothing, with status 0, only when the path is genuinely missing. The
# reader check mirrors devflow-policy.mjs's --closure probe: the flag's name
# must appear in the reader's own source.
#
# This helper is a governing file: callers run the merge base's copy, never
# the branch's (dev-flow-support SKILL.md, step 0, "First adoption").
set -euo pipefail

die() {
    local status="$1"
    shift
    echo "merge-base-policy: $*" >&2
    exit "$status"
}

[ "$#" -eq 4 ] ||
    die 2 "usage: merge-base-policy.sh <merge-base> <merge-base-reader> <out-file> <branch-policy>"
base="$1"
reader="$2"
out="$3"
branch_policy="$4"
[ -n "$base" ] || die 2 "the merge base is empty — indeterminate, never 'no merge-base policy'"
[ -n "$reader" ] || die 2 "the merge-base reader path is empty"
[ -n "$out" ] || die 2 "the output path is empty"
[ -n "$branch_policy" ] || die 2 "the branch policy path is empty"

commit="$(git rev-parse --verify --quiet "${base}^{commit}")" ||
    die 2 "merge base '$base' is not a commit in this repository — indeterminate"

entry="$(git ls-tree --full-tree "$commit" -- .devflow.toml)" ||
    die 2 "could not list .devflow.toml at $commit — indeterminate"

if [ -z "$entry" ]; then
    # A dangling symlink still counts as a branch policy: the reader then
    # fails loudly on it rather than this helper choosing the fallback.
    if [ ! -e "$branch_policy" ] && [ ! -L "$branch_policy" ]; then
        echo none
        exit 0
    fi
    [ -f "$reader" ] && [ -r "$reader" ] ||
        die 2 "the merge-base reader '$reader' is not a readable file — indeterminate"
    grep -Fq -- 'merge-base-policy-absent' "$reader" ||
        die 1 "the merge-base reader ($reader) predates --merge-base-policy-absent and would ignore it, letting the branch policy govern — refusing"
    echo absent
    exit 0
fi

case "$entry" in
100644" blob "* | 100755" blob "*) ;;
*) die 2 ".devflow.toml at $commit is not a regular file ($entry) — indeterminate" ;;
esac
git cat-file blob "${commit}:.devflow.toml" >"$out" ||
    die 2 "could not materialize .devflow.toml at $commit — indeterminate"
echo present
