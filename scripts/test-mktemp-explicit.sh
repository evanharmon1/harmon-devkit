#!/usr/bin/env bash
# Reject a bare `mktemp` / `mktemp -d` (no template argument) in test scripts.
#
# On macOS a bare `mktemp -d` ignores TMPDIR and returns a /var/folders path,
# and /var is a symlink to /private/var. A test that sets TMPDIR to steer where
# scratch lands, or compares a scratch path with a physically resolved one,
# then fails on every Mac while passing on Ubuntu (#2009, #1457). The fix is an
# explicit parent: `mktemp -d "${TMPDIR:-/tmp}/name.XXXXXX"`, followed by
# `pwd -P` where the path is compared.
#
# Scans scripts/test-*.sh and template/scripts/test-*.sh (whichever exist),
# including template suites whose name carries a Copier [% if %] conditional.
#
# Two ways a bare call is allowed, both reviewable in a diff:
#   1. A same-line `# mktemp: allow -- REASON` pragma (REASON non-blank) for a
#      call whose location genuinely does not matter.
#   2. A count in scripts/mktemp-baseline.txt ("<path> <count>") for calls that
#      predate this guard and have not been judged yet. The count must EQUAL
#      the actual number of bare calls in that file: a new bare call fails, and
#      so does fixing one without lowering the count, so the debt can only
#      shrink. A `template/` copy is keyed by its rendered `scripts/...` path. Entries
#      for files a repo does not have are ignored (the file ships to consumers
#      alongside only some of the suites it lists).
# `--baseline` prints the current counts in baseline format.
#
# A line-oriented heuristic, not a shell parser: an argument is any word after
# `mktemp` that does not start with `-`, up to the next `) ; | & < > \``. It can
# miscount an unusual construct (use the pragma, or lower/raise the baseline in
# review) but is exact for the `$(mktemp -d)` and `var=$(mktemp)` forms.
# Must stay portable to macOS bash 3.2 (no mapfile) and BSD awk.
set -euo pipefail
cd "$(dirname "$0")/.."

baseline_file=scripts/mktemp-baseline.txt

# scan FILE -> prints "LINE:TEXT" for each unallowed bare mktemp call (a line holding two prints two rows).
scan() {
    awk '
        {
            line = $0
            if (line ~ /^[[:space:]]*#/) next
            if (line ~ /# mktemp: allow --[[:space:]]*[^[:space:]]/) next
            rest = line
            offset = 0
            while ((p = index(rest, "mktemp")) > 0) {
                prev = (offset + p > 1) ? substr(line, offset + p - 1, 1) : ""
                after = substr(rest, p + 6)
                offset += p + 5
                rest = after
                # A word that merely contains mktemp (a path, a name) is not a call.
                if (prev ~ /[A-Za-z0-9_\/.-]/) continue
                # `command -v mktemp` / `which mktemp` look the tool up, not call it.
                if (substr(line, 1, offset - 6) ~ /(-v|which|type)[[:space:]]+$/) continue
                args = after
                sub(/[);|&<>`].*/, "", args)
                sub(/[[:space:]]+[0-9]+[[:space:]]*$/, "", args)   # 2>/dev/null leaves "2"
                n = split(args, w, /[[:space:]]+/)
                explicit = 0
                for (i = 1; i <= n; i++) if (w[i] != "" && w[i] !~ /^-/) explicit = 1
                if (!explicit) printf "%d:%s\n", FNR, line   # one row per call, so a line with two counts twice
            }
        }
    ' "$1"
}

# norm PATH -> PATH with Copier conditional markers ([% if x %]...[% endif %]) removed.
norm() { printf '%s\n' "$1" | sed 's/\[%[^%]*%\]//g'; }

# key FILE -> the baseline key: template/scripts/[% if x %]test-y.sh[% endif %] -> scripts/test-y.sh
key() { norm "${1#template/}"; }

# count FILE -> number of unallowed bare calls.
count() { scan "$1" | wc -l | tr -d ' '; }

# Exercise the scanner before trusting its repository-wide result.
self_test() (
    fixtures="$(mktemp -d "${TMPDIR:-/tmp}/mktemp-explicit.XXXXXX")"
    trap 'rm -rf "$fixtures"' EXIT
    # Fixture calls are written with printf, and the tool name is assembled at
    # runtime, so this source holds no literal call for the guard to count.
    mt="$(printf 'mk%s' temp)"
    printf 'tmp="$(%s -d)"\n' "$mt" >"$fixtures/bare-d.sh"
    printf 'f=$(%s)\n' "$mt" >"$fixtures/bare.sh"
    printf 'x="$(%s 2>/dev/null)" || return 2\n' "$mt" >"$fixtures/bare-redirect.sh"
    printf 'tmp=$(%s -d) || exit 1\n' "$mt" >"$fixtures/bare-or.sh"
    printf '%s -d | tee out\n' "$mt" >"$fixtures/bare-pipe.sh"
    printf 'a="$(%s -d)"; b="$(%s -d)"\n' "$mt" "$mt" >"$fixtures/two-per-line.sh"
    printf 'tmp="$(%s -d "${TMPDIR:-/tmp}/x.XXXXXX")"\n' "$mt" >"$fixtures/explicit.sh"
    printf 'f="$(%s /tmp/x.XXXXXX 2>/dev/null)"\n' "$mt" >"$fixtures/explicit-redirect.sh"
    printf 'tmp="$(%s -p "$dir" -d)"\n' "$mt" >"$fixtures/explicit-p.sh"
    printf '# tmp="$(%s -d)"\n' "$mt" >"$fixtures/comment.sh"
    printf 'REAL=$(command -v %s)\ncat >"$bin/%s"\n' "$mt" "$mt" >"$fixtures/word.sh"
    printf 'tmp="$(%s -d)" # mktemp: allow -- location irrelevant\n' "$mt" >"$fixtures/allowed.sh"
    printf 'tmp="$(%s -d)" # mktemp: allow --   \n' "$mt" >"$fixtures/empty-reason.sh"
    for f in bare-d bare bare-redirect bare-or bare-pipe empty-reason; do
        [ "$(count "$fixtures/$f.sh")" = 1 ] || {
            echo "test-mktemp-explicit: self-test failed: missed $f.sh" >&2
            exit 1
        }
    done
    [ "$(key "template/scripts/[% if a == 'b' and c != d %]test-x.sh[% endif %]")" = scripts/test-x.sh ] || {
        echo "test-mktemp-explicit: self-test failed: conditional name not normalized" >&2
        exit 1
    }
    [ "$(count "$fixtures/two-per-line.sh")" = 2 ] || {
        echo "test-mktemp-explicit: self-test failed: two calls on one line not both counted" >&2
        exit 1
    }
    for f in explicit explicit-redirect explicit-p comment word allowed; do
        [ "$(count "$fixtures/$f.sh")" = 0 ] || {
            echo "test-mktemp-explicit: self-test failed: rejected $f.sh" >&2
            exit 1
        }
    done
)

files() {
    for dir in scripts template/scripts; do
        [ -d "$dir" ] || continue
        # Copier wraps a conditionally shipped suite's name in [% if %] markers;
        # classify the rendered name, report the source path.
        find "$dir" -maxdepth 1 -type f | sort | while IFS= read -r file; do
            case "$(norm "${file##*/}")" in test-*.sh) printf '%s\n' "$file" ;; esac
        done
    done
}

if [ "${1:-}" = --baseline ]; then
    files | while IFS= read -r file; do
        n="$(count "$file")"
        [ "$n" -eq 0 ] || printf '%s %s\n' "$(key "$file")" "$n"
    done | sort -u
    exit 0
fi

self_test

failed=0
while IFS= read -r file; do
    n="$(count "$file")"
    allowed=0
    if [ -f "$baseline_file" ]; then
        allowed="$(awk -v k="$(key "$file")" '$1 == k { print $2 }' "$baseline_file" | head -n 1)"
        allowed="${allowed:-0}"
    fi
    if [ "$n" -gt "$allowed" ]; then
        echo "test-mktemp-explicit: $file: $n bare mktemp call(s), $allowed allowed" >&2
        scan "$file" | sed "s|^|  $file:|" >&2
        echo "  Pass an explicit parent: mktemp -d \"\${TMPDIR:-/tmp}/name.XXXXXX\" (then pwd -P to compare paths)," >&2
        echo "  or mark a call whose location does not matter with '# mktemp: allow -- REASON'." >&2
        failed=1
    elif [ "$n" -lt "$allowed" ]; then
        echo "test-mktemp-explicit: $file: $n bare call(s) but $baseline_file allows $allowed; lower it to $n" >&2
        failed=1
    fi
done < <(files)
[ "$failed" -eq 0 ] || exit 1
echo 'test-mktemp-explicit: PASS'
