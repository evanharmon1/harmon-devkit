#!/usr/bin/env bash
# test-lint-shell-robustness.sh — unit tests for lint-shell-robustness.sh.
#
# The guard is deliberately over-eager and has no shell parser, so this suite
# is organised around that contract rather than around a lexer's corner cases:
#
#   1. every forbidden shape is flagged, including in contexts a parser would
#      have excused — comments, here-doc bodies, quoted strings, subshells;
#   2. the ELEVEN inputs that made the previous, parsing version of this guard
#      report a file CLEAN are each flagged now (see "mooted bypasses" below);
#   3. the fixed shapes and ordinary non-pipeline greps are not flagged;
#   4. an exemption must state a reason, and a marker without one is itself a
#      finding — the escape hatch cannot be used silently.
#
# shell-robustness: exempt-file — every forbidden construct below is a
# deliberate fixture. This file IS the guard's corpus of things that must be
# flagged, so annotating each one individually would say nothing a reader
# cannot already see from the assertion names.
#
# Run via `task test:lint-shell-robustness`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
GUARD="$repo/scripts/lint-shell-robustness.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}

# fixture NAME BODY_FILE — write a fixture script and print its path. The body
# always arrives through a file so a here-doc in the fixture cannot terminate
# the one that carried it.
fixture() {
    local name="$1" body="$2"
    local path="$TMPROOT/$name"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        cat "$body"
    } >"$path"
    printf '%s\n' "$path"
}

expect_clean() {
    local desc="$1" path="$2" output
    if output="$("$GUARD" "$path" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected the guard to pass)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

# expect_flagged DESC PATH NEEDLE — rejected AND for the stated reason. A
# rejection that fires for an unrelated reason is a passing test proving
# nothing.
expect_flagged() {
    local desc="$1" path="$2" needle="$3" output
    if output="$("$GUARD" "$path" 2>&1)"; then
        bad "$desc (expected a non-zero exit)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif grep -qF -- "$needle" <<<"$output"; then
        ok "$desc"
    else
        bad "$desc (rejected, but not for the expected reason: missing '$needle')"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

body="$TMPROOT/body"

echo "==> the forbidden pipeline is flagged wherever it appears"

cat >"$body" <<'BODY'
printf '%s\n' "$out" | grep -qF hello
BODY
expect_flagged "a plain pipeline" "$(fixture plain.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
seq 1 3 | grep --quiet 2
seq 1 3 | grep -F -q 2
BODY
expect_flagged "long --quiet and a split option word" \
    "$(fixture flags.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
printf '%s\n' "$x" |
    grep -q needle
BODY
expect_flagged "a pipeline continued onto the next line" \
    "$(fixture continued.sh "$body")" 'continued'

cat >"$body" <<'BODY'
printf '%s\n' "$x" \
    | grep -q needle
BODY
expect_flagged "a continuation whose next line leads with the pipe" \
    "$(fixture leading-pipe.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
printf '%s\n' "$x" | grep \
    -q needle
BODY
expect_flagged "grep options continued onto the next line" \
    "$(fixture cont-opts.sh "$body")" 'options continue'

echo "==> contexts a parser would have excused are flagged too, by design"

cat >"$body" <<'BODY'
# A comment mentioning printf | grep -q needle as prose.
BODY
expect_flagged "the shape named inside a comment" \
    "$(fixture in-comment.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
sh -c 'grep -A5 -F "$2" "$1" | grep -qF "$3"' sh a b c
BODY
expect_flagged "the shape inside a quoted sh -c argument" \
    "$(fixture in-quotes.sh "$body")" 'grep -q'

cat >"$body" <<'BODY'
cat >"$bin/gh" <<'STUB'
printf '%s' "$*" | grep -q issueType
STUB
BODY
expect_flagged "the shape inside a here-doc body" \
    "$(fixture in-heredoc.sh "$body")" 'grep -q'

echo "==> the eleven bypasses of the previous, parsing guard (all mooted)"

# Each of these made the lexer-based version report the file CLEAN. The
# restructure deletes the lexer, so all of them are simply text now.
printf 'grep -qF a <<<"$f"\nprintf "%%s\\n" "$y" | grep -qF b\n' >"$body"
expect_flagged "1. a herestring earlier in the file" \
    "$(fixture m1.sh "$body")" 'grep -q'

printf '# do not reopen quoting\nprintf "%%s\\n" "$y" | grep -q b\n' >"$body"
expect_flagged "2. an apostrophe in a comment" "$(fixture m2.sh "$body")" 'grep -q'

printf 'x="$(\nprintf hi\n)"\nprintf "%%s\\n" "$y" | grep -q b\n' >"$body"
expect_flagged "3. a multi-line command substitution" \
    "$(fixture m3.sh "$body")" 'grep -q'

printf "x='a\nb' # don't reopen\nprintf \"%%s\\\\n\" \"\$y\" | grep -q b\n" >"$body"
expect_flagged "4. a quote closing mid-line before a comment" \
    "$(fixture m4.sh "$body")" 'grep -q'

printf 'cat <<A <<B\nx\nA\ny\nB\nprintf "%%s\\n" "$y" | grep -q b\n' >"$body"
expect_flagged "5. several here-docs opened by one command" \
    "$(fixture m5.sh "$body")" 'grep -q'

printf 'cat <<EOF-X\nf\nEOF-X\nprintf "%%s\\n" "$y" | grep -q b\n' >"$body"
expect_flagged "6. an unquoted here-doc delimiter with punctuation" \
    "$(fixture m6.sh "$body")" 'grep -q'

printf 'x="`printf "%%s" "$v" | grep -q needle`"\n' >"$body"
expect_flagged "7. a legacy backtick substitution inside double quotes" \
    "$(fixture m7.sh "$body")" 'grep -q'

printf 'printf "%%s\\n" "$x" | grep \\\n    -q needle\n' >"$body"
expect_flagged "8. grep options continued across a line" \
    "$(fixture m8.sh "$body")" 'options continue'

printf 'ok()\n{\n    pass=$((pass+1))\n    echo "x"\n}\n' >"$body"
expect_flagged "9. a reporter whose opening brace is on its own line" \
    "$(fixture test-m9.sh "$body")" 'return 0'

printf 'ok() {\n    pass=$((pass+1))\n    log "$*"\n}\n' >"$body"
expect_flagged "10. a reporter that delegates its printing" \
    "$(fixture test-m10.sh "$body")" 'return 0'

printf '( printf "%%s\\n" "$x" | grep -q n )\n' >"$body"
expect_flagged "11. a pipeline inside a subshell" \
    "$(fixture m11.sh "$body")" 'grep -q'

echo "==> the fixed shapes and ordinary greps are accepted"

cat >"$body" <<'BODY'
grep -qF hello <<<"$out"
grep -q needle < <(some-command --flag)
grep -qE '^x$' "$file"
out="$(cmd)" && grep -q needle <<<"$out"
BODY
expect_clean "herestring, process substitution, file grep, capture-then-grep" \
    "$(fixture fixed.sh "$body")"

cat >"$body" <<'BODY'
seq 1 3 | grep -c 2
seq 1 3 | grep 2 >/dev/null
seq 1 3 | grep -v 2 | wc -l
BODY
expect_clean "a non-quiet grep, which reads its input to EOF" \
    "$(fixture nonquiet.sh "$body")"

cat >"$body" <<'BODY'
if [ "$rc" -ne 0 ] || grep -qi 'unknown flag' "$file"; then :; fi
[ "$(printf '%s\n' "$x" | grep -c .)" -eq 2 ] || exit 1
expect_fail "no match" \
    grep -qF 'Old Project' "$TABLE"
BODY
expect_clean "an || chain, a counting grep, and a backslash-continued argument list" \
    "$(fixture lookalikes.sh "$body")"

echo "==> reporter helpers"

cat >"$body" <<'BODY'
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
function bad {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}
BODY
expect_clean "reporters that end in return 0, in two spellings" \
    "$(fixture test-good.sh "$body")"

cat >"$body" <<'BODY'
fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
BODY
expect_clean "a reporter that exits — its status is never read" \
    "$(fixture test-exits.sh "$body")"

cat >"$body" <<'BODY'
ok() {
    pass=$((pass + 1))
    echo "  ok $*"
}
BODY
expect_clean "the reporter scan is scoped to test-*.sh suites" \
    "$(fixture helper-lib.sh "$body")"

echo "==> an exemption must state a reason"

cat >"$body" <<'BODY'
printf '%s\n' "$x" | grep -q y # shell-robustness: ok — quoted fixture text, not code
BODY
expect_clean "an inline exemption with a reason suppresses the finding" \
    "$(fixture exempt-inline.sh "$body")"

cat >"$body" <<'BODY'
printf '%s\n' "$x" | grep -q y # shell-robustness: ok
BODY
expect_flagged "an inline exemption with NO reason is itself a finding" \
    "$(fixture exempt-noreason.sh "$body")" 'no reason'

cat >"$body" <<'BODY'
# shell-robustness: begin-exempt — a frozen snapshot that must keep its defect
printf '%s\n' "$x" | grep -q y
# shell-robustness: end-exempt
printf '%s\n' "$z" | grep -q w
BODY
expect_flagged "a block exemption covers its region and nothing after it" \
    "$(fixture exempt-block.sh "$body")" ':6:'

# Review round 1 found three ways the escape hatch or the reporter scan could
# be slipped. Each is pinned here.

cat >"$body" <<'BODY'
producer | grep --quiet x # shell-robustness: ok
BODY
expect_flagged "a reason must follow the MARKER, not merely appear on the line" \
    "$(fixture reason-anchored.sh "$body")" 'no reason'

cat >"$body" <<'BODY'
ok() { echo "check $*"; }
BODY
expect_flagged "a one-line reporter definition is inspected" \
    "$(fixture test-oneline.sh "$body")" 'return 0'

cat >"$body" <<'BODY'
ok() { echo "check $*"; return 0; }
BODY
expect_clean "a one-line reporter that ends in return 0" \
    "$(fixture test-oneline-ok.sh "$body")"

cat >"$body" <<'BODY'
fail() { echo "boom" >&2; exit 1; }
BODY
expect_clean "a one-line reporter that exits" \
    "$(fixture test-oneline-exits.sh "$body")"

cat >"$body" <<'BODY'
# shell-robustness: begin-exempt — a real reason, but never closed
x=1
printf '%s\n' "$y" | grep -q boom
BODY
expect_flagged "an unclosed begin-exempt is an error, not a licence to EOF" \
    "$(fixture unclosed-block.sh "$body")" 'never closed'

cat >"$body" <<'BODY'
# shell-robustness: end-exempt
BODY
expect_flagged "an end-exempt with no open block is reported" \
    "$(fixture stray-end.sh "$body")" 'no open'

echo "==> the guard reads what it is asked to read"

if out="$("$GUARD" "$TMPROOT/definitely-absent.sh" 2>&1)"; then
    bad "a missing named file was reported clean"
elif grep -qF 'no such file' <<<"$out"; then
    ok "a missing named file is refused, not silently skipped"
else
    bad "a missing named file failed, but not with 'no such file'"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
fi

echo "==> the hazard the guard exists for is real, and the fixed shapes are not"

# The guard's premise, exercised rather than asserted. The fixed shapes are the
# hard assertion; the legacy shape's verdict is a diagnostic, because it is a
# race and pinning it would be pinning a probability.
big="$(seq 1 40000)"
haystack="NEEDLE
$big"

if grep -qF NEEDLE <<<"$haystack"; then
    ok "herestring: a match on a $((${#haystack} / 1024)) KiB payload reads as a match"
else
    bad "herestring: a match on a $((${#haystack} / 1024)) KiB payload read as a FAILURE"
fi

if grep -qF NEEDLE < <(printf '%s\n' "$haystack"); then
    ok "process substitution: the same match reads as a match"
else
    bad "process substitution: the same match read as a FAILURE"
fi

cat >"$TMPROOT/legacy-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
haystack="$(cat "$1")"
printf '%s\n' "$haystack" | grep -qF NEEDLE
PROBE

printf '%s\n' "$haystack" >"$TMPROOT/haystack.txt"
legacy=0
bash "$TMPROOT/legacy-probe.sh" "$TMPROOT/haystack.txt" || legacy=$?
case "$legacy" in
0) echo "  · note: the legacy pipeline happened to report the match this run" || true ;;
141) echo "  · note: the legacy pipeline reported 141 (SIGPIPE) for a MATCH" \
    "— the defect, reproduced" || true ;;
*) echo "  · note: the legacy pipeline exited $legacy (not the SIGPIPE path)" || true ;;
esac

echo "==> the guard is wired to the real tree"
if "$GUARD" >/dev/null 2>&1; then
    ok "the repository's own shell scripts pass the guard"
else
    bad "the repository's own shell scripts do not pass the guard"
    "$GUARD" 2>&1 | sed 's/^/      /' >&2 || true
fi

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
